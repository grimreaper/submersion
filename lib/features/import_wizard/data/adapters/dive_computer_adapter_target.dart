part of 'dive_computer_adapter.dart';

/// The name of the profile [diverId], or null when there is no such profile.
typedef DiverNameLookup = Future<String?> Function(String diverId);

/// Which profile a download goes to (issue #2050), kept beside the adapter so
/// the adapter file does not grow further.
///
/// A computer is looked up in the active profile first and then across every
/// profile, so a computer that belongs to another profile is recognised
/// instead of registered a second time. When its owner is another existing
/// profile, the bundle carries an [ImportTargetChoice] and the import goes to
/// the chosen profile: the owner by default, or the active profile when the
/// diver turned "Add downloads to the computer's owner" off.
extension _DiveComputerAdapterTarget on DiveComputerAdapter {
  /// Runs [find] for the active profile and, when that misses, across every
  /// profile. The active profile's record wins, so a computer the old
  /// behaviour registered under two profiles keeps using this profile's copy.
  /// An unscoped library (no active id) is searched once, as before.
  Future<T?> _findAcrossProfiles<T>(
    Future<T?> Function(String? diverId) find,
  ) async {
    final own = await find(_activeDiverId);
    if (own != null || _activeDiverId.isEmpty) return own;
    return find(null);
  }

  /// Works out the computer's owner once the computer is known, and the
  /// starting choice when the diver has not made one.
  Future<void> _resolveTarget() async {
    _ownerDiverId = null;
    final owner = computer?.diverId?.trim() ?? '';
    final isOtherProfile =
        owner.isNotEmpty &&
        _activeDiverId.isNotEmpty &&
        owner != _activeDiverId;
    if (!isOtherProfile || await _lookUpDiverName(owner) == null) {
      _chosenDiverId = null;
      return;
    }
    _ownerDiverId = owner;
    _chosenDiverId ??= _followComputerOwner ? owner : _activeDiverId;
  }

  /// The bundle's choice, or null when the download simply goes to the
  /// active profile.
  ImportTargetChoice? get _targetChoice {
    final owner = _ownerDiverId;
    if (owner == null) return null;
    return ImportTargetChoice(
      ownerDiverId: owner,
      chosenDiverId: targetDiverId,
    );
  }

  /// The import's per-profile outcome when its dives went to a profile other
  /// than the active one, so tagging, the logbook rules and the summary's
  /// "By profile" section follow that profile. Empty otherwise, as for any
  /// import into the active profile.
  Future<List<DiverImportOutcome>> _diverOutcomes(
    List<String> importedDiveIds,
  ) async {
    final target = targetDiverId;
    if (_activeDiverId.isEmpty || target == _activeDiverId) return const [];
    return [
      DiverImportOutcome(
        diverId: target,
        name: await _lookUpDiverName(target) ?? '',
        isNew: false,
        isActive: false,
        diveIds: importedDiveIds,
      ),
    ];
  }

  /// The name of [diverId], or null when it is missing or cannot be read.
  Future<String?> _lookUpDiverName(String diverId) async {
    try {
      final lookup = _diverName;
      if (lookup != null) return await lookup(diverId);
      final ref = _ref;
      if (ref == null) return null;
      final diver = await ref
          .read(diverRepositoryProvider)
          .getDiverById(diverId);
      return diver?.name;
    } catch (e, stackTrace) {
      DiveComputerAdapter._log.error(
        'Could not look up profile $diverId',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}
