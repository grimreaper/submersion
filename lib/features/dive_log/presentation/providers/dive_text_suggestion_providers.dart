import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_text_suggestion_field.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_repository_provider.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';

/// The active diver's earlier values for one free-text dive field, most
/// recent first (#3229). Refreshes whenever the dives table is written, so a
/// boat logged on another device appears after sync.
final diveTextSuggestionsProvider =
    FutureProvider.family<List<String>, DiveTextSuggestionField>((
      ref,
      field,
    ) async {
      final repository = ref.watch(diveRepositoryProvider);
      final diverId = ref.watch(currentDiverIdProvider);
      ref.invalidateSelfWhen(repository.watchDivesChanges());
      return repository.getRecentTextValues(field, diverId: diverId);
    });
