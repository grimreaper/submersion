import 'package:flutter/widgets.dart';

/// Tells a page whether the route holding it has finished sliding in.
///
/// A route animation advances by elapsed time, so a page that builds
/// everything in the opening frames of its slide makes that slide jump: the
/// next frame lands already part of the way across (issue #3489). A heavy
/// page builds what it can afford during the slide and the rest once
/// [isRouteEntranceSettled] turns true.
///
/// A page with no slide to wait for (the initial route, a deep link, a page
/// with no transition, or one outside any route) is settled from its first
/// build. Once settled it stays settled, so sliding back out never tears the
/// page down again.
mixin RouteEntranceSettled<T extends StatefulWidget> on State<T> {
  ModalRoute<Object?>? _route;
  Animation<double>? _entrance;
  bool _settled = false;

  /// Whether the route's entrance animation has completed.
  bool get isRouteEntranceSettled => _settled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settled) return;
    final route = ModalRoute.of(context);
    final entrance = route?.animation;
    if (route == null || entrance == null) {
      _stopListening();
      _settled = true;
      return;
    }
    _route = route;
    if (!identical(entrance, _entrance)) {
      _stopListening();
      _entrance = entrance..addStatusListener(_onEntranceStatus);
    }
    _settled = !_isEntering(entrance.status);
    if (_settled) _stopListening();
  }

  /// Whether the route is still on its way in. A hero controller builds a
  /// pushed route offstage for its first frame, its animation reading
  /// complete, to measure where heroes land; the slide only starts once the
  /// route comes back onstage.
  bool _isEntering(AnimationStatus status) =>
      (_route?.offstage ?? false) || status == AnimationStatus.forward;

  /// Settles only when the slide arrives. One that turns back, because the
  /// page was popped or a back swipe began mid-entrance, builds nothing on
  /// its way out; one that a cancelled swipe sends forward again still
  /// arrives.
  void _onEntranceStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _isEntering(status)) return;
    _stopListening();
    if (mounted) setState(() => _settled = true);
  }

  void _stopListening() {
    _entrance?.removeStatusListener(_onEntranceStatus);
    _entrance = null;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }
}
