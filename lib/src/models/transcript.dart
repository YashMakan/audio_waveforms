class Word {
  final String text;
  final Duration startTime;
  final Duration endTime;

  const Word({
    required this.text,
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'start_time_ms': startTime.inMilliseconds,
    'end_time_ms': endTime.inMilliseconds,
  };

  factory Word.fromJson(Map<String, dynamic> json) => Word(
    text: json['word'] as String,
    startTime: Duration(milliseconds: (json['start'] as double).toInt()),
    endTime: Duration(milliseconds: (json['end'] as double).toInt()),
  );
}

class Transcript {
  final String fullText;
  final List<Word> words;

  const Transcript({
    required this.fullText,
    required this.words,
  });

  Map<String, dynamic> toJson() => {
    'full_text': fullText,
    'words': words.map((w) => w.toJson()).toList(),
  };

  factory Transcript.fromJson(Map<String, dynamic> json) {
    final wordsList = json['words'] as List<dynamic>;
    return Transcript(
      fullText: json['full_text'] as String? ?? '',
      words: wordsList.map((w) {
        // Convert each word map to Map<String, dynamic>
        if (w is Map) {
          return Word.fromJson(Map<String, dynamic>.from(w));
        }
        throw Exception('Invalid word format');
      }).toList(),
  );
  }
}