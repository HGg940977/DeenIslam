# Full Adhan at prayer time (works with the app closed)

The app plays the Adhan from the scheduled prayer notification, so Android
itself plays the sound and the app does not need to be running.

## Enable it
1. Obtain an Adhan recording you are **licensed to redistribute** (your own
   licence/permission; this repo does not ship one).
2. Save it as `mobile/android/app/src/main/res/raw/adhan.mp3`
   (`.ogg` also works; keep the base name exactly `adhan`, lowercase).
3. Recommended: 30-60 seconds, mono/stereo, under ~1 MB.
4. Commit and push. The next APK build detects the file automatically and
   shows the "full Adhan" switch in the prayer settings.

## Behaviour and limits
- Plays through the notification channel, so it follows the phone's volume,
  silent mode and Do-Not-Disturb. The app does not bypass them.
- Needs notification permission (Android 13+). Without the exact-alarm
  permission, delivery can be a few minutes late.
- A sound that is changed later requires a new channel id (Android keeps a
  channel's sound); change `_adhanChannelId` in `reminder_service.dart`.
- Some phone makers (Xiaomi, Oppo, Vivo, Huawei, Samsung power saving) kill
  background apps; the user may need to allow the app to run in the background.
- Not tested on a physical device in this repo's CI.
