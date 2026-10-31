# Safeguard: demo script (about 4 minutes)

One story: **fast checks on the phone, a Meta model for judgment, and a guardian who can watch live from anywhere.**

## Before you go on stage (5 minutes)

- [ ] Phone charged, unlocked, plugged in; app reinstalled this week (a free Apple ID build lasts 7 days).
- [ ] Open the guardian page once to wake the server: https://safeguard-backend-1067547469878.asia-south1.run.app (opens the guardian page)
- [ ] Supabase project not paused (the guardian page loads and sign-in works).
- [ ] Telegram: the guardian and one contact have pressed Start in @SafeguardAlertsUjjwalBot.
- [ ] Settings: "Send real alerts" on; standing live link on; guardian code entered.
- [ ] Second device (or laptop) open on the guardian page, signed in with the guardian code.
- [ ] Mac not needed: everything runs on Cloud Run + Supabase.

## The run

1. **Open the app, sign in** (30 s). Say: "An account is compulsory, so every alert has a name behind it." Show the profile photo (optional).
2. **Dashboard** (20 s). Point at: protection status, 112 / 1091 helplines, "Police near me", and the safe-arrival timer.
3. **Protect** (45 s). Tap Start protecting on the Dashboard; the live view opens. Make the hostile gesture in front of the camera; show the counter go up. The red **SOS** button on this screen starts an SOS with the usual cancellable countdown. Say: "Detection runs on the phone, so it is fast and the video does not leave it."
4. **SOS** (60 s). Start an SOS (distress word or button). Show: countdown (cancellable), then the live map, nearby police and hospitals, the Telegram alert arriving on the second phone / laptop with the live link.
5. **Guardian page** (60 s). On the laptop: live video with sound, the location trail, then the evidence log: names heard, plates seen, gesture moments, each rated possible or strongly possible. Tap Ask Muse on a moment and read the answer. Say: "One continuous recording, even if the phone breaks, and a log of who and what to look for."
6. **End the SOS** (10 s), then show the finished recording on the guardian page as one video with sound.
7. **Close** (20 s). "Muse judges the conversation and the scene. Next: Meta glasses as the live camera and microphone, with spoken prompts to the wearer."

## If something goes wrong

| Problem | What to do |
|---|---|
| No network at the venue | On the sign-in screen tap **Continue offline for now**. Detection, countdown, helplines and the timer all work; say alerts and the live link need a connection. Use phone hotspot first if you can. |
| Server slow on first request | It scales to zero. Open the guardian page a few minutes before. |
| Gesture not detected | Show it face-on, hand held steady for about a second. Fall back to the voice trigger. |
| Telegram alert late | Show the live link directly from the SOS screen. |

## What is proven, and what is not (say this honestly if asked)

- **Working on a real iPhone:** accounts, protection, gestures and expressions, SOS, live link, guardian page, continuous recording, Telegram alerts, helplines.
- **Planned, not built:** Meta glasses as the live camera and microphone source, with spoken prompts to the wearer.
- **Limits:** the safe-arrival timer lives on the phone, so it cannot fire if the app is force-closed or the phone is off. Hindi text has not had a native review.
