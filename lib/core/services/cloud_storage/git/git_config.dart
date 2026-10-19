import 'package:submersion/core/services/cloud_storage/git/git_remote.dart';

/// The branch Submersion syncs to unless the diver picks another.
const String kDefaultGitBranch = 'submersion-sync';

/// Host families, used only to choose token help text. Connections work the
/// same for every host.
enum GitHostKind { github, gitlab, bitbucket, giteaLike, other }

GitHostKind detectGitHost(Uri cloneUrl) {
  final host = cloneUrl.host.toLowerCase();
  if (host == 'github.com') return GitHostKind.github;
  if (host == 'bitbucket.org') return GitHostKind.bitbucket;
  if (host.contains('gitlab')) return GitHostKind.gitlab;
  if (host == 'codeberg.org' ||
      host == 'gitea.com' ||
      host.contains('gitea') ||
      host.contains('forgejo')) {
    return GitHostKind.giteaLike;
  }
  return GitHostKind.other;
}

const Set<String> _loopbackHosts = {'127.0.0.1', 'localhost', '::1'};

final RegExp _forbiddenRefChars = RegExp(r'[\s~^:?*\[\\\x00-\x1f\x7f]');

/// Whether Git would accept [name] as a branch name (the `check-ref-format`
/// rules that apply to a single branch).
bool isValidGitBranchName(String name) {
  if (name.isEmpty || name == '@') return false;
  if (name.startsWith('-') || name.startsWith('/') || name.endsWith('/')) {
    return false;
  }
  if (name.startsWith('refs/')) return false;
  if (name.endsWith('.') || name.endsWith('.lock')) return false;
  if (name.contains('..') || name.contains('@{') || name.contains('//')) {
    return false;
  }
  if (_forbiddenRefChars.hasMatch(name)) return false;
  for (final part in name.split('/')) {
    if (part.startsWith('.') || part.endsWith('.lock')) return false;
  }
  return true;
}

/// What is wrong with a [GitConfig], one value per kind of mistake.
enum GitConfigProblem {
  repoUrl,
  credentialsInUrl,
  repoQuery,
  repoPath,
  username,
  token,
  tokenSpaces,
  branch,
}

/// Connection settings for a Git repository.
///
/// Immutable. The factory normalizes its inputs so the same repository typed
/// different ways is one address and one account: whitespace trimmed, the
/// host lowercased, `www.github.com` folded into `github.com`, trailing
/// slashes dropped and `.git` appended. [toString] never prints the token.
class GitConfig {
  const GitConfig._({
    required this.repoUrl,
    required this.username,
    required this.token,
    required this.branch,
    required this.pinnedCertSha256,
  });

  factory GitConfig({
    required String repoUrl,
    required String username,
    required String token,
    String branch = kDefaultGitBranch,
    String? pinnedCertSha256,
  }) {
    final pin = pinnedCertSha256?.trim();
    return GitConfig._(
      repoUrl: _normalizeUrl(repoUrl),
      username: username.trim(),
      token: token.trim(),
      branch: branch.trim(),
      pinnedCertSha256: pin == null || pin.isEmpty ? null : pin.toLowerCase(),
    );
  }

  /// The normalized clone address as text.
  final String repoUrl;
  final String username;
  final String token;
  final String branch;

  /// Lowercase hex SHA-256 of a self-signed certificate the user trusted.
  final String? pinnedCertSha256;

  static String _normalizeUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return trimmed;
    var host = uri.host.toLowerCase();
    if (host == 'www.github.com') host = 'github.com';
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isNotEmpty && !path.endsWith('.git')) path = '$path.git';
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: host,
      port: uri.hasPort ? uri.port : null,
      path: path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }

  Uri get cloneUrl => Uri.tryParse(repoUrl) ?? Uri(path: repoUrl);

  String get host => cloneUrl.host;

  /// The repository path without the leading slash and `.git`
  /// (`you/dive-log`, `group/sub/repo`).
  String get repoPath {
    var path = cloneUrl.path;
    if (path.startsWith('/')) path = path.substring(1);
    if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
    return path;
  }

  GitHostKind get hostKind => detectGitHost(cloneUrl);

  String get displayLabel => '$repoPath @ $host';

  GitRemote toRemote() => GitRemote(
    cloneUrl: cloneUrl,
    username: username,
    token: token,
    pinnedCertSha256: pinnedCertSha256,
  );

  /// Every problem with this config, in field order: address, username,
  /// token, branch. The settings form shows each under its own field.
  ///
  /// The address must be https. [allowLoopbackHttp] also accepts plain http
  /// to this machine, for tests against a local server only: the token
  /// travels in every request, so the app never sets it.
  List<GitConfigProblem> problems({bool allowLoopbackHttp = false}) {
    final out = <GitConfigProblem>[];
    final uri = Uri.tryParse(repoUrl);
    final loopbackHttp =
        allowLoopbackHttp &&
        uri != null &&
        uri.scheme == 'http' &&
        _loopbackHosts.contains(uri.host);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && !loopbackHttp)) {
      out.add(GitConfigProblem.repoUrl);
    } else if (uri.userInfo.isNotEmpty) {
      out.add(GitConfigProblem.credentialsInUrl);
    } else if (uri.hasQuery || uri.hasFragment) {
      out.add(GitConfigProblem.repoQuery);
    } else if (repoPath.isEmpty) {
      out.add(GitConfigProblem.repoPath);
    }
    if (username.isEmpty) out.add(GitConfigProblem.username);
    if (token.isEmpty) {
      out.add(GitConfigProblem.token);
    } else if (token.contains(RegExp(r'\s'))) {
      out.add(GitConfigProblem.tokenSpaces);
    }
    if (!isValidGitBranchName(branch)) out.add(GitConfigProblem.branch);
    return out;
  }

  /// English description of the first problem, or null when valid. The
  /// settings form validates field by field with localized text; this is
  /// the service-layer backstop.
  String? validate({bool allowLoopbackHttp = false}) {
    final first = problems(allowLoopbackHttp: allowLoopbackHttp).firstOrNull;
    return switch (first) {
      null => null,
      GitConfigProblem.repoUrl =>
        'Enter the repository address, starting with https://',
      GitConfigProblem.credentialsInUrl =>
        'Put the username and token in their own fields, not in the address',
      GitConfigProblem.repoQuery =>
        'The repository address cannot contain ? or #',
      GitConfigProblem.repoPath =>
        'Enter the full repository address, including its path',
      GitConfigProblem.username => 'Enter the username',
      GitConfigProblem.token => 'Enter the access token',
      GitConfigProblem.tokenSpaces => 'The access token cannot contain spaces',
      GitConfigProblem.branch => 'Enter a valid branch name',
    };
  }

  GitConfig copyWith({
    String? repoUrl,
    String? username,
    String? token,
    String? branch,
    String? pinnedCertSha256,
    bool clearPin = false,
  }) => GitConfig(
    repoUrl: repoUrl ?? this.repoUrl,
    username: username ?? this.username,
    token: token ?? this.token,
    branch: branch ?? this.branch,
    pinnedCertSha256: clearPin
        ? null
        : (pinnedCertSha256 ?? this.pinnedCertSha256),
  );

  Map<String, Object?> toJson() => {
    'repoUrl': repoUrl,
    'username': username,
    'token': token,
    'branch': branch,
    'pinnedCertSha256': pinnedCertSha256,
  };

  /// Throws [TypeError] on a malformed blob; callers treat that as absent.
  factory GitConfig.fromJson(Map<String, Object?> json) => GitConfig(
    repoUrl: json['repoUrl'] as String,
    username: json['username'] as String,
    token: json['token'] as String,
    branch: json['branch'] as String? ?? kDefaultGitBranch,
    pinnedCertSha256: json['pinnedCertSha256'] as String?,
  );

  @override
  String toString() => 'GitConfig($displayLabel, branch: $branch)';
}
