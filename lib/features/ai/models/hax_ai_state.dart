class HaxAiState {
  const HaxAiState({this.apiKey = '', this.loading = false});

  final String apiKey;
  final bool loading;

  HaxAiState copyWith({String? apiKey, bool? loading}) {
    return HaxAiState(
      apiKey: apiKey ?? this.apiKey,
      loading: loading ?? this.loading,
    );
  }
}
