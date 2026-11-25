/// Everything the app says out loud.
///
/// Spoken rather than written because the people using this may not read. Keep
/// each line one short spoken sentence — a phrase that reads well on screen is
/// often too long to listen to.
enum Phrase {
  startWork,
  finishWork,
  findingLocation,
  tooFar,
  weakLocation,
  blinkTwice,
  turnLeft,
  turnRight,
  checkingFace,
  workStarted,
  workFinished,
  faceNotMatched,
  registerFaceFirst,
  addSiteFirst,
  lookAtCamera,
}

class SpokenLanguage {
  const SpokenLanguage({
    required this.code,
    required this.ttsLocale,
    required this.nativeName,
    this.spokenVia,
  });

  /// Borrow another language's voice when this one has none installed.
  ///
  /// Urdu and Hindi are the same spoken language and differ mainly in script,
  /// so Urdu on screen read aloud by the Hindi voice is understood — whereas
  /// handing Arabic script to a Hindi engine is not.
  final String? spokenVia;

  /// Shown in the language's own script: picking a language from a list
  /// written in Latin script is itself a literacy barrier.
  final String nativeName;
  final String code;
  final String ttsLocale;
}

const supportedLanguages = <SpokenLanguage>[
  SpokenLanguage(code: 'en', ttsLocale: 'en-US', nativeName: 'English'),
  SpokenLanguage(code: 'hi', ttsLocale: 'hi-IN', nativeName: 'हिंदी'),
  SpokenLanguage(code: 'ml', ttsLocale: 'ml-IN', nativeName: 'മലയാളം'),
  SpokenLanguage(code: 'ta', ttsLocale: 'ta-IN', nativeName: 'தமிழ்'),
  SpokenLanguage(
    code: 'ur',
    ttsLocale: 'ur-PK',
    nativeName: 'اردو',
    spokenVia: 'hi',
  ),
  SpokenLanguage(code: 'bn', ttsLocale: 'bn-IN', nativeName: 'বাংলা'),
];

SpokenLanguage languageByCode(String code) => supportedLanguages.firstWhere(
      (l) => l.code == code,
      orElse: () => supportedLanguages.first,
    );

/// Translations are machine-written and should be checked by a native speaker
/// before this is used for real: an awkward instruction is worse than silence.
const phrases = <String, Map<Phrase, String>>{
  'en': {
    Phrase.startWork: 'Press the green button to start work',
    Phrase.finishWork: 'Press the red button to finish work',
    Phrase.findingLocation: 'Finding your location',
    Phrase.tooFar: 'You are too far from work. Please go closer.',
    Phrase.weakLocation:
        'Your location is not clear. Stand in the open and try again.',
    Phrase.blinkTwice: 'Blink your eyes two times',
    Phrase.turnLeft: 'Turn your head to the left',
    Phrase.turnRight: 'Turn your head to the right',
    Phrase.checkingFace: 'Checking your face',
    Phrase.workStarted: 'Work started',
    Phrase.workFinished: 'Work finished',
    Phrase.faceNotMatched: 'Face not recognised. Please try again.',
    Phrase.registerFaceFirst: 'First register your face',
    Phrase.addSiteFirst: 'First add your work place',
    Phrase.lookAtCamera: 'Look at the camera',
  },
  'hi': {
    Phrase.startWork: 'काम शुरू करने के लिए हरा बटन दबाइए',
    Phrase.finishWork: 'काम खत्म करने के लिए लाल बटन दबाइए',
    Phrase.findingLocation: 'आपकी जगह पता की जा रही है',
    Phrase.tooFar: 'आप काम की जगह से बहुत दूर हैं। पास जाइए।',
    Phrase.weakLocation: 'जगह साफ़ पता नहीं चली। खुली जगह में खड़े होकर फिर कोशिश करें।',
    Phrase.blinkTwice: 'दो बार आँख झपकाइए',
    Phrase.turnLeft: 'अपना सिर बाईं ओर घुमाइए',
    Phrase.turnRight: 'अपना सिर दाईं ओर घुमाइए',
    Phrase.checkingFace: 'आपका चेहरा जाँचा जा रहा है',
    Phrase.workStarted: 'काम शुरू हो गया',
    Phrase.workFinished: 'काम खत्म हो गया',
    Phrase.faceNotMatched: 'चेहरा पहचाना नहीं गया। फिर कोशिश कीजिए।',
    Phrase.registerFaceFirst: 'पहले अपना चेहरा दर्ज कीजिए',
    Phrase.addSiteFirst: 'पहले अपनी काम की जगह जोड़िए',
    Phrase.lookAtCamera: 'कैमरे की ओर देखिए',
  },
  'ml': {
    Phrase.startWork: 'ജോലി തുടങ്ങാൻ പച്ച ബട്ടൺ അമർത്തുക',
    Phrase.finishWork: 'ജോലി അവസാനിപ്പിക്കാൻ ചുവന്ന ബട്ടൺ അമർത്തുക',
    Phrase.findingLocation: 'നിങ്ങളുടെ സ്ഥലം കണ്ടെത്തുന്നു',
    Phrase.tooFar: 'നിങ്ങൾ ജോലിസ്ഥലത്തു നിന്ന് വളരെ അകലെയാണ്. അടുത്തേക്ക് പോകുക.',
    Phrase.weakLocation: 'സ്ഥലം വ്യക്തമല്ല. തുറന്ന സ്ഥലത്ത് നിന്ന് വീണ്ടും ശ്രമിക്കുക.',
    Phrase.blinkTwice: 'രണ്ടു തവണ കണ്ണ് ചിമ്മുക',
    Phrase.turnLeft: 'തല ഇടത്തേക്ക് തിരിക്കുക',
    Phrase.turnRight: 'തല വലത്തേക്ക് തിരിക്കുക',
    Phrase.checkingFace: 'നിങ്ങളുടെ മുഖം പരിശോധിക്കുന്നു',
    Phrase.workStarted: 'ജോലി തുടങ്ങി',
    Phrase.workFinished: 'ജോലി അവസാനിച്ചു',
    Phrase.faceNotMatched: 'മുഖം തിരിച്ചറിഞ്ഞില്ല. വീണ്ടും ശ്രമിക്കുക.',
    Phrase.registerFaceFirst: 'ആദ്യം നിങ്ങളുടെ മുഖം രജിസ്റ്റർ ചെയ്യുക',
    Phrase.addSiteFirst: 'ആദ്യം ജോലിസ്ഥലം ചേർക്കുക',
    Phrase.lookAtCamera: 'ക്യാമറയിലേക്ക് നോക്കുക',
  },
  'ta': {
    Phrase.startWork: 'வேலையைத் தொடங்க பச்சை பொத்தானை அழுத்தவும்',
    Phrase.finishWork: 'வேலையை முடிக்க சிவப்பு பொத்தானை அழுத்தவும்',
    Phrase.findingLocation: 'உங்கள் இடம் கண்டறியப்படுகிறது',
    Phrase.tooFar: 'நீங்கள் வேலை இடத்திலிருந்து வெகு தொலைவில் உள்ளீர்கள். அருகில் செல்லவும்.',
    Phrase.weakLocation: 'இடம் தெளிவாக இல்லை. திறந்த இடத்தில் நின்று மீண்டும் முயற்சிக்கவும்.',
    Phrase.blinkTwice: 'இரண்டு முறை கண் சிமிட்டவும்',
    Phrase.turnLeft: 'தலையை இடதுபுறம் திருப்பவும்',
    Phrase.turnRight: 'தலையை வலதுபுறம் திருப்பவும்',
    Phrase.checkingFace: 'உங்கள் முகம் சரிபார்க்கப்படுகிறது',
    Phrase.workStarted: 'வேலை தொடங்கியது',
    Phrase.workFinished: 'வேலை முடிந்தது',
    Phrase.faceNotMatched: 'முகம் அடையாளம் காணப்படவில்லை. மீண்டும் முயற்சிக்கவும்.',
    Phrase.registerFaceFirst: 'முதலில் உங்கள் முகத்தைப் பதிவு செய்யவும்',
    Phrase.addSiteFirst: 'முதலில் வேலை இடத்தைச் சேர்க்கவும்',
    Phrase.lookAtCamera: 'கேமராவைப் பாருங்கள்',
  },
  'ur': {
    Phrase.startWork: 'کام شروع کرنے کے لیے سبز بٹن دبائیں',
    Phrase.finishWork: 'کام ختم کرنے کے لیے سرخ بٹن دبائیں',
    Phrase.findingLocation: 'آپ کی جگہ تلاش کی جا رہی ہے',
    Phrase.tooFar: 'آپ کام کی جگہ سے بہت دور ہیں۔ قریب جائیں۔',
    Phrase.weakLocation: 'جگہ صاف معلوم نہیں ہوئی۔ کھلی جگہ پر کھڑے ہو کر دوبارہ کوشش کریں۔',
    Phrase.blinkTwice: 'دو بار آنکھ جھپکائیں',
    Phrase.turnLeft: 'اپنا سر بائیں طرف موڑیں',
    Phrase.turnRight: 'اپنا سر دائیں طرف موڑیں',
    Phrase.checkingFace: 'آپ کا چہرہ جانچا جا رہا ہے',
    Phrase.workStarted: 'کام شروع ہو گیا',
    Phrase.workFinished: 'کام ختم ہو گیا',
    Phrase.faceNotMatched: 'چہرہ پہچانا نہیں گیا۔ دوبارہ کوشش کریں۔',
    Phrase.registerFaceFirst: 'پہلے اپنا چہرہ رجسٹر کریں',
    Phrase.addSiteFirst: 'پہلے اپنی کام کی جگہ شامل کریں',
    Phrase.lookAtCamera: 'کیمرے کی طرف دیکھیں',
  },
  'bn': {
    Phrase.startWork: 'কাজ শুরু করতে সবুজ বোতাম টিপুন',
    Phrase.finishWork: 'কাজ শেষ করতে লাল বোতাম টিপুন',
    Phrase.findingLocation: 'আপনার অবস্থান খোঁজা হচ্ছে',
    Phrase.tooFar: 'আপনি কাজের জায়গা থেকে অনেক দূরে আছেন। কাছে যান।',
    Phrase.weakLocation: 'জায়গা পরিষ্কার বোঝা যায়নি। খোলা জায়গায় দাঁড়িয়ে আবার চেষ্টা করুন।',
    Phrase.blinkTwice: 'দুইবার চোখ পিটপিট করুন',
    Phrase.turnLeft: 'আপনার মাথা বাঁ দিকে ঘোরান',
    Phrase.turnRight: 'আপনার মাথা ডান দিকে ঘোরান',
    Phrase.checkingFace: 'আপনার মুখ পরীক্ষা করা হচ্ছে',
    Phrase.workStarted: 'কাজ শুরু হয়েছে',
    Phrase.workFinished: 'কাজ শেষ হয়েছে',
    Phrase.faceNotMatched: 'মুখ চেনা যায়নি। আবার চেষ্টা করুন।',
    Phrase.registerFaceFirst: 'প্রথমে আপনার মুখ নিবন্ধন করুন',
    Phrase.addSiteFirst: 'প্রথমে কাজের জায়গা যোগ করুন',
    Phrase.lookAtCamera: 'ক্যামেরার দিকে তাকান',
  },
};

String phraseText(String languageCode, Phrase phrase) =>
    phrases[languageCode]?[phrase] ?? phrases['en']![phrase]!;
