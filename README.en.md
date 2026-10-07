<p align="right">
  <a href="README.en.md"><img alt="ENG" src="https://img.shields.io/badge/ENG-English-1f6feb?style=for-the-badge"></a>
  <a href="README.md"><img alt="RUS" src="https://img.shields.io/badge/RUS-%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-2ea043?style=for-the-badge"></a>
</p>

# GestureControl

**Sign language translation, touch-free gesture control and speech-to-text on iPhone and Android**

> 🚧 **Beta.** The project is being tested. Expect bugs, imperfect recognition and changes in future versions. Please send feedback and ideas through [Issues](../../issues) — English is welcome.

> 🌍 **Language of the app.** The app's interface is in **Russian**, the voice that reads translations aloud is Russian, and speech-to-text currently recognises **Russian**. Sign translation works with any sign language: you teach the app your own signs and type the words for them in any language (words in other languages are read aloud by the Russian voice). This guide gives the English meaning of every button.

> 📱 **iPhone** — iOS 17 or later, branch [`beta-0.46`](../../tree/beta-0.46).
>
> 🤖 **Android** — Android 8.0 or later: now lives in its own repository, [**SignSpeech/Android**](https://github.com/SignSpeech/Android) (version beta-0.6, guide in English and Russian).
>
> iPad, Mac and the simulator are not supported: the simulator has no camera.

> 🆕 **Current version — beta-0.46** for iPhone (branch [`beta-0.46`](../../tree/beta-0.46)) and **beta-0.6** for Android ([SignSpeech/Android](https://github.com/SignSpeech/Android)). See [What's new](#whats-new-in-beta-046).
>
> 📦 **The latest code is in the `beta-0.46` branch (iPhone).** The `main` branch holds the first version of the app. To install the latest version, download that branch (see [Installation](#installation)).

---

## What's new in beta-0.46

**Update for iPhone and Android** — branches [`beta-0.46`](../../tree/beta-0.46) (iPhone) and [`beta-0.46_only_android`](../../tree/beta-0.46_only_android/Android) (Android; the newer Android version is in [SignSpeech/Android](https://github.com/SignSpeech/Android)). Recorded signs are kept.

**🎯 Fewer sign recognition mistakes**
- **Similar words are no longer confused.** If two words are shown almost the same way (for example, the same hand shape at the chin and at the chest), the app automatically makes the match stricter for them. Words that are not similar work as before.
- **Transitions between signs no longer become extra words.** A pose counts only once the fingers have stopped moving: in-between hand positions are no longer taken for a word.
- A word counts only if it is clearly closer than the second most similar word (the margin was raised from 10% to 15%).
- If some word is now recognised less often, record it 1–2 more times or move **Чувствительность** (Sensitivity) slightly to the right.

**🗣 Speech of a person 10 metres away**
- Speech-to-text boosts quiet and distant voices: automatic volume (up to 16×), a filter for low hum (ventilation, traffic) and a limiter so loud sounds don't distort. Background noise is not boosted. On by default — the ear button 👂 at the bottom of the page.
- New button 🎧 **Bluetooth microphone**: give the speaker headphones with a microphone, and they can be heard from any distance, even in noise.
- Point the bottom of the phone (the microphone) at the speaker. In a quiet room speech from 10 metres is recognised; in a noisy one, headphones work better. See [Person far away](#person-far-away-up-to-10-metres).
- On Android the boost works on Android 13 and later and is experimental: if the phone's speech service does not accept audio from the app, the app goes back to the normal microphone by itself and says so.

**🎨 Softer, easier interface**
- Calm colours instead of bright green and red: mint, teal, amber, peach. Rounded cards and smooth animations.
- Bigger buttons that are easier to hit. The main button **Речь → текст** (Speech → text) stands out in colour.
- On the speech-to-text page each phrase has its own card; the phrase still being spoken is highlighted in soft amber.
- A light vibration when a word is translated, so you don't have to watch the screen.

## What's new: a resting second hand no longer interferes

**✋ beta-0.45 update for iPhone and Android** (branches [`beta-0.45`](../../tree/beta-0.45) and [`beta-0.45_only_android`](../../tree/beta-0.45_only_android))
- A one-hand sign is recognised even if the other hand is visible — lying on a table or on the lap. A still, lowered hand is ignored and drawn in grey.
- As soon as the second hand rises or starts moving, it counts again: two-hand signs work as before.
- When recording a pose, a lowered hand is no longer recorded, so a sign is not saved as a "two-hand" sign by mistake. If a one-hand sign was poorly recognised because of the other hand, record it again.

---

## What's new: Android version

**🤖 The app is now available for Android phones** — today in its own repository [SignSpeech/Android](https://github.com/SignSpeech/Android) (first released in branch [`beta-0.45_only_android`](../../tree/beta-0.45_only_android/Android)).

- Everything the iPhone app does: sign translation (poses and moving signs, one or two hands), Control mode, recording signs from three angles, the "Similar to…" hint, sensitivity, shoulder tracking, automatic light, spoken translation and speech-to-text.
- Written in Kotlin (Jetpack Compose, CameraX). Hand points (the same 21 per hand) and shoulders are found by **Google MediaPipe**; speech is recognised by Android's speech service (usually Google).
- The sign and speech-correction algorithms are the same as on iPhone and are covered by tests.
- The app is called **speech** on the phone, and its icon is St Isaac's Cathedral, as on iPhone.
- The Android sign dictionary is separate: signs have to be recorded again.
- ⚠️ Beta: not yet tested on many real Android phones. If something does not build or work, send a screenshot through [Issues](../../issues).

---

## What's new in beta-0.45

**📞 Translating a phone call — experimental**
- Answer a call, go to the home screen (the call continues) and open **speech**: the speech-to-text page opens by itself and tries to listen to the conversation.
- ⚠️ **Tested on iPhone: it does not work.** During a call the iPhone does not give the app the microphone (error 561017449 — "the call has higher priority"). There is no permission for this, neither in the iPhone settings nor for developers. See [Translating a phone call](#translating-a-phone-call-experimental-beta-045) for what to do instead. A call cannot be translated on Android either.

---

## What's new in beta-0.41

This version is all about **speech-to-text**: recognition became more reliable and easier to use.

- **New icon and name:** the app is called **speech** on the iPhone, and its icon is St Isaac's Cathedral. The Xcode project is still called **GestureControl**.
- 🔧 **Fixed:** all audio always goes to recognition (earlier, speech in buses and on the street, where the voice is barely louder than noise, was not recognised).
- **New setting "New line after a pause"** (**…** button): 0.8 s — when speakers take turns quickly; 1.2 s — normal; 2 s — for slow speech or long pauses inside a phrase (for example, stuttering).
- A long monologue is split at the nearest pause, not in the middle of a word; no audio is lost between phrases.
- After a call, an alarm, Siri or minimising the app, listening resumes by itself. Plugging in or removing headphones restarts audio by itself.
- If the recognition server is unavailable, recognition runs on the phone (on iPhones that support it).
- A volume bar shows how loud the microphone hears the sound; it turns mint/green when it sounds like a voice.
- You can scroll up and re-read: the text no longer jumps. The **К новым** (To new) button returns to the live text (iOS 18+).
- Text correction: repeated groups of words ("I want I want to go" → "I want to go"), stretched sounds and filler sounds ("uhhh", "mmm") are removed.

---

## What's new in beta-0.4

- **🎙 Speech → text:** a new page shows everything said around you as large text, live. When several people talk, each remark after a pause starts on a new line.
- Text is corrected for speech difficulties: stutters, repeats and filler sounds are removed.
- **Мои слова** (My words): names and terms that must be recognised exactly. If such a word is recognised with a 1–2 letter mistake, it is corrected. Words from the sign dictionary are included automatically.
- Text size is changed with the **Aa** button. The camera is off while the page is open.
- **Screen brightness** returns to normal as soon as the app is no longer active.

---

## What's new in beta-0.25

- **Shoulders:** the app finds the shoulders on every frame (Apple Vision) and takes into account where the hand is relative to the body. The same hand shape at the chin, at the chest and at the shoulder now means different words. If the shoulders are not visible, signs are recognised by the hands only. To turn off: **Словарь** (Dictionary) → **Учитывать плечи** (Use shoulders).
- **More accurate poses:** finger extension was added to the bend angles; the app knows whether it is the right or left hand; a sign is compared with the three nearest recorded examples.
- **More accurate moving signs:** the app picks the leading (moving) hand by itself; a still hand is not taken for a moving sign; part of a long sign is not counted as a short sign; "left" and "right" are not confused; a word counts at the moment of best match.
- **Hint under the sign:** "Похоже на «слово» — N%" (Similar to "word" — N%). 100% means the sign is similar enough to count. For a rejected moving sign the reason is shown in brackets: "мало движения" (too little movement), "слишком быстро" (too fast), "кисть не меняет форму" (hand shape doesn't change).

**Results on synthetic data** (3D hand model, different people, half of the tests with the left hand; not tested on real recordings):

| | beta-0.2 | beta-0.25 |
|---|---|---|
| Poses: recognised correctly | 66–71% | 84% |
| Poses: wrong sign named | 7–11% | 4% |
| Poses: false matches on other poses | 38% | 18% |
| Moving signs: recognised correctly | 84% | 96% |
| Moving signs: wrong word | 13% | 2% |
| Moving signs: extra matches per sign | ~2 | ~0 |
| One hand shape in 4 places near the body | 12% | ~60% |

---

## What it is

GestureControl recognises hands through the iPhone camera and turns signs into text, speech and commands — and the speech of people around you into text.

Modes:

- **🗣 Перевод (Translation, sign language).** A person shows signs, and the app immediately shows the words on screen in large text and says them aloud. It translates the signs it has been taught: poses and moving signs, with one or two hands.
- **🎛 Управление (Control).** Built-in gestures control the interface without touching the screen: switch screens, pause, change volume.
- **🎙 Речь → текст (Speech → text).** A separate page: whatever is said around you (including by several people) immediately appears on screen in large text.

Sign recognition runs on the phone itself, **without the internet**; video is never sent anywhere. Speech-to-text uses Apple speech recognition: audio is usually processed on Apple servers (internet needed); on supported iPhones you can turn on **Только на телефоне** (On device only).

## Features

- Up to two hands at once, 21 key points per hand.
- Hand skeleton drawn over the camera image in real time.
- Automatic shoulder tracking: the app knows where the hands are relative to the body (at the chin, at the chest, at the shoulder).
- Camera switch:
  - **back camera** — point the phone at the person signing: translation on screen and by voice;
  - **front camera** — the signer sees whether the translation is correct.
- Teach a new sign in a couple of seconds: poses and moving signs.
- Works for different people: the app compares angles and distances between fingers, not finger length; the left hand is understood as a mirror of the right.
- Smoothed hand points: the skeleton doesn't shake; a finger hidden when the hand turns counts less and doesn't break recognition.
- Automatic light in the dark: the flashlight for the back camera, the screen for the front camera. It turns off by itself when it gets light.
- Adjustable sensitivity; the threshold for each word is tuned automatically.
- A warning when a new sign is similar to an already recorded word.
- Translations read aloud (in Russian), even in silent mode.
- Speech-to-text: live transcription, remarks of different people on new lines, stutter and repeat correction, your own word list.
- A phrase ends by itself when you lower your hands for 2 seconds.
- The sign dictionary is saved on the phone.

## How it works

```
Camera → video frames → hand detection (21 points per hand) and shoulders → smoothing
       → pose, position and movement features → comparison with the dictionary (k-NN / DTW)
       → word or command → text, speech, action
```

1. **Hand detection.** Apple Vision, built into iOS (`VNDetectHumanHandPoseRequest`), finds up to two hands and 21 points on each: the wrist, the joints and the fingertips. For each point Vision reports a confidence, and for each hand whether it is right or left.
2. **Shoulders.** On every frame Apple Vision (`VNDetectHumanBodyPoseRequest`) finds the shoulders of the person nearest to the camera. Shoulders are smoothed with the same filter as hand points.
3. **Smoothing.** Each hand point is smoothed with a **One Euro** filter: jitter is removed at rest, and there is almost no lag during fast movement.
4. **Features that are the same for different people.** 33 features per hand: 15 joint bend angles, 4 finger spread angles, 4 distances from the thumb tip to the other fingertips, 5 finger extensions (wrist-to-tip distance), palm side, hand direction and the palm centre relative to the middle between the shoulders (in shoulder widths, so the distance from the camera doesn't matter). Angles and distance ratios hardly depend on finger length, hand size or distance to the camera. Poorly visible points count less. For two-hand signs the position of the hands relative to each other is also used. A sign recorded with the right hand is recognised for left-handed people too: it is compared in mirrored form.
5. **Poses** (no movement) are recognised with the nearest-neighbour method (**k-NN**, k = 3).
6. **Moving signs** are recognised with **DTW** (dynamic time warping). The last 1.5–3 seconds are resampled to 15 frames per second and compared with the recorded examples. DTW allows a sign to be shown faster or slower than when recorded. A sign counts when the similarity stops growing.
7. **Protection against false matches.**
   - Each word's threshold is chosen automatically from the spread of its recordings; similar words get stricter thresholds.
   - If two words match almost equally well, neither counts.
   - A pose counts only when the hand shape has settled; transitions between signs are not taken for words.
   - "Sticky" threshold: a recognised sign doesn't flicker at the threshold, and a short glitch doesn't reset holding a pose.
   - A still hand is not taken for a moving sign; a resting lowered second hand is ignored.
8. **Automatic light.** Scene brightness comes from the frame metadata (EXIF BrightnessValue). The light turns on if it has been dark for more than 1 second and turns off when it gets noticeably brighter.

## Requirements

| What you need | Version |
|---|---|
| iPhone | iOS 17.0 or later |
| Mac | with Xcode 16 or later |
| Apple ID | a regular, free one |
| Cable | to connect the iPhone to the Mac |

A paid Apple developer account is not needed.

## Installation

The app is not in the App Store yet, so it is built from source code in Xcode. It takes 5–10 minutes.

> 🤖 **For Android** — see [SignSpeech/Android](https://github.com/SignSpeech/Android): a step-by-step guide in English, using Android Studio instead of Xcode.

### 1. Download the project

The latest version is in the **`beta-0.46`** branch.

**Option A: as a ZIP.** At the top left of this page choose the **beta-0.46** branch, then click the green **Code → Download ZIP** button and unpack the archive.

**Option B: with Git** (in Terminal):

```bash
git clone -b beta-0.46 https://github.com/Fen1x678/sign_language_interpretation_on_camera.git
```

### 2. Open the project in Xcode

Open the downloaded folder, then the **GestureControl** folder, and double-click **`GestureControl.xcodeproj`** (blue icon).

> ⚠️ Open the `.xcodeproj` file, not the folder. Otherwise Xcode can't build the app for iPhone.

### 3. Set up signing

1. In the left panel click the top **GestureControl** line (blue icon).
2. Under **TARGETS** choose **GestureControl**.
3. Open the **Signing & Capabilities** tab.
4. In **Team** choose your Apple ID (**Personal Team**).
   - If it's not in the list: **Add an Account…** → sign in with your Apple ID.
   - If a **Set Up Signing…** button appears, click it and then **Set Up**.
5. Change **Bundle Identifier** to your own unique one, for example `com.<your-name>.gesturecontrol`. If Xcode says it is taken, add some digits at the end.

### 4. Prepare the iPhone

1. Connect the iPhone to the Mac with a cable, unlock it and tap **Trust This Computer**.
2. Turn on **Developer Mode** on the iPhone: **Settings → Privacy & Security → Developer Mode**. The phone restarts; then confirm.

### 5. Run

1. In the Xcode toolbar choose your iPhone in the device list.
2. Click **▶** or press **⌘R**.
3. The first build can take a minute. If Xcode asks for your Mac password to access the keychain, enter it and click **Always Allow**.

### 6. Allow the app on the iPhone

On the first launch the iPhone shows **Untrusted Developer**. To allow the app:

**Settings → General → VPN & Device Management → Apple Development: your Apple ID → Trust**

Then press **⌘R** in Xcode again or just open the app on the phone. When the app asks for camera access, allow it.

> ℹ️ With a free Apple ID the app works for **7 days**. Then connect the phone and press **⌘R** in Xcode again. The app updates over the old one; recorded signs are kept.

## How to use

The app's buttons are in Russian; their English meanings are given in brackets.

### Translation mode — «Перевод»

**First, teach the app the signs you need:**

1. Tap **«＋ Словарь»** (Dictionary) and type a word or phrase (in any language).
2. Choose the sign type:
   - **С движением** (With movement) — for most signs. After the 3-2-1 countdown show the whole sign at a normal pace (2.5 seconds);
   - **Поза** (Pose) — for signs without movement, for example letters of the fingerspelling alphabet. Hold the pose for 2 seconds.
3. Tap **«Записать жест»** (Record sign). With **С трёх ракурсов** (From three angles) on, recording runs 3 times: straight, slightly left and slightly right.

💡 Record each word 2–3 times, ideally by 2–3 different people. The more examples, the more accurate the translation for everyone.

⚙️ The **Dictionary** has a **Чувствительность** (Sensitivity) slider: if signs are not recognised, move it right; if extra words appear, move it left.

🔦 The flashlight button at the top: **Авто** (Auto — turns on by itself in the dark), **Всегда вкл.** (Always on) or **Выключена** (Off).

**Then translate:**

- show signs to the camera — words appear on screen and are spoken aloud;
- lower your hands for 2 seconds to end the phrase;
- buttons under the text: ⌫ erase the last word, ✓ **Готово** (Done) end the phrase, ▶ say it again, 🔊 voice on/off, 🗑 clear.

### Control mode — «Управление»

| Gesture | Command |
|---|---|
| 👍 Thumb up | Confirm |
| ✋ Open palm | Pause / continue |
| ☝️ Index finger | Select |
| ➡️ Move hand right | Next screen |
| ⬅️ Move hand left | Previous screen |
| ⬆️ Move hand up | Volume up |
| ⬇️ Move hand down | Volume down |

Hold a static gesture for about 0.4 seconds; it fires once.

### Tips for accurate recognition

- Keep your hands 30–80 cm from the camera so the whole hand is in the frame.
- For hand position relative to the body to count, the shoulders must be visible (a line between the shoulders on screen). Record signs the same way you will show them later.
- Watch the hint "Похоже на … — N%" (Similar to … — N%): if the percentage is high but the word doesn't count, move **Sensitivity** right.
- You need enough light: in the dark the automatic light turns on. Bright light behind you gets in the way.
- A plain background works best.
- Record signs by several people if different people will use the app.

### Speech → text — «Речь → текст»

1. In Translation mode tap **«Речь → текст»** (Speech → text) in the bottom panel.
2. On first use allow access to the **microphone** and **speech recognition**.
3. Put the phone near the speakers. Text appears immediately; the phrase still being spoken is amber. (Speech is recognised in Russian.)
4. The bar above the buttons is the volume the microphone hears (mint means it sounds like a voice). If it barely moves, put the phone closer to the speakers.
5. Buttons at the bottom: 🗑 clear, 👂 distant speech (boost, on by default), 🎙/⏹ listen/pause, **Aa** text size, 🎧 Bluetooth microphone.
6. Scroll up to re-read — the text won't jump. **«К новым»** (To new) returns to the live text.
7. The **…** button at the top: **Мои слова** (My words — names and terms for exact recognition), **Новая строка после паузы** (New line after a pause: 0.8 / 1.2 / 2 s), **Дальняя и тихая речь** (Distant and quiet speech), **Микрофон Bluetooth** (Bluetooth microphone) and **Только на телефоне** (On device only, no internet) if the iPhone supports it.
8. After a call or when you return to the app, listening resumes by itself.

#### Person far away (up to 10 metres)

1. Check that the ear button 👂 is on (teal) — it is on by default. The phone raises a quiet voice to normal volume and removes low hum without boosting background noise.
2. Point the **bottom of the phone (the microphone) at the speaker**. Nothing should cover the microphone.
3. The volume bar already shows the boosted sound: mint means the phone hears a voice.
4. In a quiet room speech from 10 metres is recognised. In noise (street, transport, music) noise is boosted together with the voice — then give the speaker **Bluetooth headphones with a microphone** (AirPods or any others) and tap 🎧. If no headphones are connected, the page says «Наушники Bluetooth не подключены» (Bluetooth headphones not connected) and the phone uses its own microphone.

#### Translating a phone call (experimental, beta-0.45)

1. Answer the call.
2. Go to the home screen: the call continues, with a green indicator at the top.
3. Open **speech**. During a call the speech-to-text page opens by itself.
4. Turn on the **speakerphone** so the phone's microphone hears both you and the other person.
5. The bottom of the page shows the result:
   - «Звонок: слушаю…» (Call: listening…) — the iPhone gave the app audio, the conversation appears as text;
   - «iPhone не дал приложению микрофон…» (iPhone didn't give the app the microphone…) or «iPhone отдаёт приложению тишину…» (iPhone gives the app silence…) — the iPhone protects the call, and the call can't be translated on this iPhone. When the call ends, transcription continues by itself.

> ⚠️ Tested: the iPhone does not allow it — during a call it doesn't give the app the microphone (error 561017449). Apple protects phone calls: third-party apps usually get no microphone audio during a call and never get the other person's voice. Even keyboard dictation doesn't work during a call, and iOS doesn't give apps the caller's number. What works instead:
> - **A second device.** Turn on the speakerphone and open speech-to-text on another iPhone or iPad next to the speaker.
> - **Built-in iPhone features.** Check **Settings → Accessibility → Live Captions**: it shows the conversation as text right on the call screen. Availability and supported languages depend on the iPhone model, iOS version and region.

## Beta limitations

- ❗ **The app doesn't know any sign language in advance.** It translates only signs from the dictionary the user recorded.
- The interface, the voice and speech-to-text are in Russian for now.
- Facial expressions are not used. Hand position is measured relative to the shoulders, but not to the eyes, mouth or nose.
- Single words are recognised, not sign language grammar.
- The dictionary is stored on one phone only; there is no export yet.
- The camera sees hands in 2D: if a sign is turned sideways to the camera, accuracy drops.
- Only the back camera has a flashlight; the front camera uses the screen as a light, which is weaker.
- Speech-to-text doesn't tell people apart by voice: remarks are separated by pauses. If two people speak at once, their speech ends up on one line.
- Speech-to-text corrects stutters, repeats and words from **My words**, but can't guess every misrecognised word: with strong speech difficulties accuracy is lower.
- Without the internet, speech-to-text works only on iPhones that can recognise speech on the device (the switch is automatic).
- In strong noise (transport, loud music) accuracy is lower. The phone boosts a distant voice (up to 10 m), but in noise the noise is boosted too: give the speaker Bluetooth headphones or keep the phone closer.
- A phone call can't be translated: neither iPhone nor Android give apps the call audio or the caller's number.
- Tested on a limited number of devices.

## Plans

- [ ] A built-in Russian Sign Language model based on the open [Slovo](https://github.com/hukenovs/slovo) dataset (1000 signs) — translation without teaching.
- [ ] Fingerspelling alphabet based on the [Bukva](https://arxiv.org/abs/2410.08675) dataset.
- [ ] Dictionary export and import, sharing dictionaries between users.
- [x] Hand position relative to the shoulders (beta-0.25).
- [ ] Facial expressions and hand position relative to the face.
- [x] Android version ([SignSpeech/Android](https://github.com/SignSpeech/Android)).
- [ ] English interface and English speech recognition.
- [ ] TestFlight and App Store release.

## Project structure

Files of the latest iPhone version (branch `beta-0.46`). The Android version is in [SignSpeech/Android](https://github.com/SignSpeech/Android).

```
sign_language_interpretation_on_camera/
├── README.md, README.en.md
├── LICENSE
└── GestureControl/
    ├── GestureControl.xcodeproj      — Xcode project (the app is called "speech" on the iPhone)
    └── GestureControl/
        ├── Assets.xcassets           — app icon
        ├── GestureControlApp.swift   — entry point
        ├── CameraManager.swift       — camera, hand detection, flashlight
        ├── GestureRecognizer.swift   — hand geometry, built-in gestures, swipes, holding
        ├── HandFeatures.swift        — pose and movement features, DTW
        ├── SignLibrary.swift         — smoothing, sign dictionary, k-NN and thresholds
        ├── PoseSteadiness.swift      — a pose counts only when the hand shape has settled
        ├── RestingHandFilter.swift   — ignores a resting lowered second hand
        ├── GestureViewModel.swift    — logic: translation, recording signs, light, commands
        ├── VoiceTranslator.swift     — speech-to-text: recognition, remarks by pauses, distant-speech boost
        ├── SpeechCorrector.swift     — correction of recognised speech: stutters, repeats, own words
        ├── SpeechView.swift          — speech-to-text page
        ├── GestureModels.swift       — gesture and command types
        ├── Theme.swift               — soft colours, cards, buttons
        ├── ContentView.swift         — interface
        └── CameraPreview.swift       — camera image and hand skeleton
```

A detailed description of the algorithms (in Russian) is in [`GestureControl/README.md`](../../blob/beta-0.46/GestureControl/README.md).

## Troubleshooting

| Problem | Solution |
|---|---|
| `Signing requires a development team` | Choose a Team on the **Signing & Capabilities** tab (step 3). |
| `Failed Registering Bundle Identifier` | Change **Bundle Identifier** to a unique one. |
| The iPhone isn't in the device list | Connect the cable, unlock the phone, tap **Trust**, turn on **Developer Mode**. |
| **Untrusted Developer** | Settings → General → VPN & Device Management → Trust. |
| The app stopped opening after a week | A free signature lasts 7 days: run it again from Xcode. |
| Black screen instead of the camera | Settings → speech → turn on **Camera**. |
| A sign isn't recognised | Record 1–2 more examples of the word (ideally by another person), check the light or move **Sensitivity** right. |
| A one-hand sign isn't recognised when the other hand is visible | Rest the other hand on the table or lap: a still lowered hand is ignored (it's grey on screen). If the sign was recorded with the other hand visible, record it again. |
| Extra words appear | Move **Sensitivity** left. |
| When recording: «похож на …» (similar to …) | The new sign is easy to confuse with an existing word. Show it differently or delete one of the words. |
| No access to the microphone or speech recognition | Settings → speech → turn on **Microphone** and **Speech Recognition**. |
| The icon or name didn't change | Restart the iPhone: the system sometimes shows a cached icon. |
| «Распознавание речи сейчас недоступно» (Speech recognition unavailable) | Check the internet or turn on **Только на телефоне** (On device only, the **…** button on the speech page), if available. |
| Speech-to-text: a phrase breaks into pieces | **…** → **Новая строка после паузы** (New line after a pause) → **2 s**. |
| Speech-to-text: different people's remarks on one line | **…** → **Новая строка после паузы** → **0.8 s**. |
| Speech-to-text: the bar barely moves, no text | The phone hears poorly: put it closer to the speakers, bottom (microphone) towards them. |
| Speech-to-text: the person is far away, no text | Check that 👂 is on (teal) and point the bottom of the phone at the speaker. In noise — Bluetooth headphones with a microphone on the speaker and the 🎧 button. |
| Tapped 🎧, but it says «Наушники Bluetooth не подключены» | Connect the headphones in **Settings → Bluetooth** and tap 🎧 again (or close and reopen the page). |
| After an update a word is recognised less often | Similar words are now checked more strictly. Record the word 1–2 more times or move **Sensitivity** slightly right. |
| During a call: the iPhone didn't give the microphone or gives silence | This is how the iPhone protects calls; the app can't bypass it. Use a second device on speakerphone or **Live Captions** (see "Translating a phone call"). |
| A moving sign isn't recognised | Look at the hint under the sign. «мало движения» (too little movement) — show the sign with the same range as when recording. «слишком быстро» (too fast) — slower. Below 100% — move **Sensitivity** right. |

## Feedback

Found a bug or have an idea? Open an [Issue](../../issues) (in English or Russian) and include:

- iPhone model and iOS version;
- what you did and what happened;
- a screenshot or video if possible.

## License

The project is licensed under **MIT** — see [LICENSE](LICENSE). You may freely use, change and port the code to other platforms (including in your own projects) as long as you keep the copyright line and the license text.

---

*Student project. Beta.*
