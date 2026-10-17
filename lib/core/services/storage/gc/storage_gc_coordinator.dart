import 'dart:async';

import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/media_store/network_status_service.dart';
import 'package:submersion/core/services/storage/gc/cloud_usage_measure.dart';
import 'package:submersion/core/services/storage/gc/storage_gc_store.dart';
import 'package:submersion/core/services/storage/scratch_sweep.dart';
import 'package:submersion/features/media_store/data/media_verify_service.dart';

/// What started a cleanup run.
enum StorageGcTrigger {
  launch,
  resume,
  timer,

  /// A restore finished; set internally when a pending restore marker is
  /// found on an automatic trigger.
  postRestore,

  /// The diver tapped "Reclaim storage".
  manual,

  /// The diver tapped "Rescan": measure the cloud, delete nothing.
  rescan,
}

/// One device sweep. A [dryRun] counts what it would reclaim.
typedef DeviceSweep =
    Future<ScratchSweepReport> Function({
      required DateTime now,
      required bool dryRun,
    });

/// Whether something last done at [last] is due again after [period].
///
/// A stamp more than a day in the future can only come from a broken clock
/// and must not suppress the work until real time catches up: the same
/// defence as `shouldSweepScratch` and `shouldAutoVerify`.
bool isCadenceDue(DateTime? last, DateTime now, Duration period) {
  if (last == null) return true;
  if (last.isAfter(now.add(const Duration(days: 1)))) return true;
  return now.difference(last) >= period;
}

/// Runs every storage sweep on one schedule under shared safety rules
/// (storage GC design, Coordinator).
///
/// Plain Dart with every dependency injected, so the schedule is testable
/// apart from Riverpod and the platform. The providers wire it to the live
/// services and kick it on launch, on resume, on a slow timer, and from the
/// Storage usage page.
///
/// - **Device part:** at most once a day, or at once after a restore or on
///   request. Every sweep is best-effort; one failing does not stop the rest.
/// - **Cloud part:** automatic runs need an unmetered network and happen at
///   most once a day. A cleanup (deletes) runs when the fleet cadence is due,
///   after a restore until a sweep is no longer deferred, or on request.
///   Otherwise a weekly measurement lists the store without deleting. Nothing
///   cloud-side runs while a sync is merging; deletes also wait while an
///   upload is transferring. Rescan and Reclaim run on any network but
///   offline, since the diver asked.
class StorageGcCoordinator {
  StorageGcCoordinator({
    required List<DeviceSweep> deviceSweeps,
    required Future<void> Function(DateTime now) localCacheSweep,
    required Future<NetworkKind> Function() network,
    required bool Function() isSyncBusy,
    required Future<bool> Function() hasTransferringUploads,
    required Future<VerifyLibraryReport?> Function({required bool dryRun})
    mediaSweep,
    required Future<bool> Function(DateTime now) fleetSweepDue,
    required Future<void> Function(DateTime now) stampFleetSweep,
    required Future<int?> Function() measureSync,
    required Future<({int bytes, bool partial})?> Function() measureLibraries,
    required StorageGcStore store,
    DateTime Function()? now,
  }) : _deviceSweeps = deviceSweeps,
       _localCacheSweep = localCacheSweep,
       _network = network,
       _isSyncBusy = isSyncBusy,
       _hasTransferringUploads = hasTransferringUploads,
       _mediaSweep = mediaSweep,
       _fleetSweepDue = fleetSweepDue,
       _stampFleetSweep = stampFleetSweep,
       _measureSync = measureSync,
       _measureLibraries = measureLibraries,
       _store = store,
       _now = now ?? DateTime.now;

  static const devicePeriod = Duration(days: 1);
  static const cloudAttemptPeriod = Duration(days: 1);
  static const measurePeriod = Duration(days: 7);

  /// How often a pending post-restore cloud cleanup retries while deferred.
  static const postRestoreRetry = Duration(hours: 1);

  final List<DeviceSweep> _deviceSweeps;
  final Future<void> Function(DateTime now) _localCacheSweep;
  final Future<NetworkKind> Function() _network;
  final bool Function() _isSyncBusy;
  final Future<bool> Function() _hasTransferringUploads;
  final Future<VerifyLibraryReport?> Function({required bool dryRun})
  _mediaSweep;
  final Future<bool> Function(DateTime now) _fleetSweepDue;
  final Future<void> Function(DateTime now) _stampFleetSweep;
  final Future<int?> Function() _measureSync;
  final Future<({int bytes, bool partial})?> Function() _measureLibraries;
  final StorageGcStore _store;
  final DateTime Function() _now;
  final _log = LoggerService.forClass(StorageGcCoordinator);

  final _changes = StreamController<void>.broadcast();
  Future<void>? _current;

  StorageGcStore get store => _store;

  /// Whether a run is in progress.
  bool get isRunning => _current != null;

  /// Fires when a run starts and when it ends.
  Stream<void> get changes => _changes.stream;

  /// Runs one pass. A call while a pass is running joins that pass.
  Future<void> run(StorageGcTrigger trigger) {
    final running = _current;
    if (running != null) return running;
    final pass = _run(trigger).whenComplete(() {
      _current = null;
      _changes.add(null);
    });
    _current = pass;
    _changes.add(null);
    return pass;
  }

  /// Bytes the device sweeps would reclaim now (a dry run of each).
  Future<int> deviceReclaimableBytes() async {
    final now = _now();
    var bytes = 0;
    for (final sweep in _deviceSweeps) {
      try {
        bytes += (await sweep(now: now, dryRun: true)).bytesReclaimed;
      } catch (e) {
        _log.warning('Device sweep measurement failed', error: e);
      }
    }
    return bytes;
  }

  void dispose() => _changes.close();

  Future<void> _run(StorageGcTrigger trigger) async {
    final now = _now();
    var effective = trigger;
    final automatic =
        trigger == StorageGcTrigger.launch ||
        trigger == StorageGcTrigger.resume ||
        trigger == StorageGcTrigger.timer;
    if (automatic && _store.postRestorePendingSince != null) {
      effective = StorageGcTrigger.postRestore;
    }
    try {
      await _devicePart(effective, now);
    } catch (e) {
      _log.warning('Device cleanup failed', error: e);
    }
    try {
      await _cloudPart(effective, now, automatic: automatic);
    } catch (e) {
      _log.warning('Cloud cleanup failed', error: e);
    }
  }

  Future<void> _devicePart(StorageGcTrigger trigger, DateTime now) async {
    if (trigger == StorageGcTrigger.rescan) return;
    final forced =
        trigger == StorageGcTrigger.manual ||
        trigger == StorageGcTrigger.postRestore;
    if (!forced && !isCadenceDue(_store.lastDeviceRun, now, devicePeriod)) {
      return;
    }
    var total = ScratchSweepReport.empty;
    for (final sweep in _deviceSweeps) {
      try {
        total += await sweep(now: now, dryRun: false);
      } catch (e) {
        _log.warning('Device sweep failed (will retry)', error: e);
      }
    }
    try {
      await _localCacheSweep(now);
    } catch (e) {
      _log.warning('Local cache sweep failed (will retry)', error: e);
    }
    await _store.setLastDeviceRun(now);
    if (!total.isEmpty) {
      await _store.setLastDeviceResult(
        AreaResult(
          bytes: total.bytesReclaimed,
          items: total.filesDeleted,
          at: now,
        ),
      );
    }
    if (trigger == StorageGcTrigger.postRestore) {
      await _store.clearPostRestorePending();
    }
  }

  Future<void> _cloudPart(
    StorageGcTrigger trigger,
    DateTime now, {
    required bool automatic,
  }) async {
    if (_isSyncBusy()) return;
    final network = await _network();
    if (network == NetworkKind.offline) return;
    final requested =
        trigger == StorageGcTrigger.manual ||
        trigger == StorageGcTrigger.rescan;
    if (!requested && network != NetworkKind.unmetered) return;

    final cloudPending = _store.postRestoreCloudPending;
    if (automatic || trigger == StorageGcTrigger.postRestore) {
      final period = cloudPending ? postRestoreRetry : cloudAttemptPeriod;
      if (!isCadenceDue(_store.lastCloudAttempt, now, period)) return;
    }

    final wantDelete =
        trigger == StorageGcTrigger.manual ||
        (trigger != StorageGcTrigger.rescan &&
            (cloudPending || await _fleetSweepDue(now)));
    final measureDue =
        requested ||
        trigger == StorageGcTrigger.postRestore ||
        isCadenceDue(_store.lastCloudMeasure, now, measurePeriod);

    final deleting = wantDelete && !await _hasTransferringUploads();
    if (!deleting && !measureDue) return;
    if (!requested) await _store.setLastCloudAttempt(now);

    final report = await _mediaSweep(dryRun: !deleting);
    if (deleting && (report == null || !report.deferred)) {
      if (report != null) await _stampFleetSweep(now);
      if (cloudPending) await _store.setPostRestoreCloudPending(false);
      if (report != null && report.orphansRemoved > 0) {
        await _store.setLastCloudResult(
          AreaResult(
            bytes: report.bytesReclaimed,
            items: report.orphansRemoved,
            at: now,
          ),
        );
      }
    }

    var partial = false;
    int? syncBytes;
    try {
      syncBytes = await _measureSync();
    } catch (e) {
      partial = true;
      _log.warning('Sync folder measurement failed', error: e);
    }
    ({int bytes, bool partial})? libraries;
    try {
      libraries = await _measureLibraries();
    } catch (e) {
      partial = true;
      _log.warning('Shared library measurement failed', error: e);
    }

    final reclaimed = deleting ? report?.bytesReclaimed ?? 0 : 0;
    await _store.setCloudUsage(
      CloudUsage(
        scannedAt: now,
        mediaBytes: report == null ? null : report.totalBytes - reclaimed,
        mediaReclaimableBytes: report == null
            ? null
            : report.reclaimableBytes - reclaimed,
        mediaWaitingBytes: report?.waitingBytes,
        syncBytes: syncBytes,
        librariesBytes: libraries?.bytes,
        partial: partial || (libraries?.partial ?? false),
      ),
    );
    await _store.setLastCloudMeasure(now);
  }
}
