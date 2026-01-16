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
    text: json['text'] as String,
    startTime: Duration(milliseconds: json['start_time_ms'] as int),
    endTime: Duration(milliseconds: json['end_time_ms'] as int),
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

  factory Transcript.fromJson(Map<String, dynamic> json) => Transcript(
    fullText: json['full_text'] as String,
    words: (json['words'] as List<dynamic>)
        .map((w) => Word.fromJson(w as Map<String, dynamic>))
        .toList(),
  );
}