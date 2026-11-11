# Pal Again Privacy Policy

Last updated: November 11, 2026

Pal Again is an independent, open-source iOS and iPadOS client. It contains no advertising SDK, behavioral analytics or tracking.

## Optional crash diagnostics

Pal Again asks once, after pairing, whether to send diagnostics. They stay off until you agree. If you agree, Pal Again sends Apple MetricKit crash and hang reports, the app version, build number, device model, operating-system version, language, and a short list of app-flow steps such as “pairing started” or “permission result.” These reports are not linked to your identity and never contain chat text, Muse tokens, account details, gadget names, filenames, photos, audio, or document contents. You can turn this off in Settings at any time.

Diagnostics are sent to a developer-operated Cloudflare Worker and stored in an EU-hosted Cloudflare D1 database for up to 30 days solely to find and fix defects. Raw IP addresses are not stored. A salted one-way hash of the source IP is retained for no more than 48 hours only to prevent abuse of the report endpoint.

## Data stored on your device

- Your Muse Gadget SDK Token and pairing credentials are stored in the iOS Keychain.
- Chat history and selected preferences are stored on the device.
- If you enable iCloud chat sync, chat text is stored in your private iCloud key-value store under your Apple ID.
- Photos stay on the device where they were selected or captured unless you explicitly send them to Muse.

You can clear local chat history, disable synchronization, revoke permissions, replace your SDK Token or remove the saved Muse pairing from the app's Settings screen.

## Data sent when you use Muse

Pal Again sends data when you use a feature, or when your paired Muse sends a command. Once you have granted an iOS permission, Muse can use it while the app is open on screen, with no further confirmation for each use. A new Apple Shortcut or local-network target always needs a tap on the device. Depending on what you use, this can include:

- chat messages and Muse responses;
- photos and voice notes you send;
- your voice during a live conversation with Muse, and Muse's voice and video back, while the conversation is open;
- camera captures and short voice recordings requested by Muse;
- device information requested by supported commands, such as location, motion, battery state or local-network results.

This information is sent to Muse services through the authenticated gadget connection. A live conversation with the "Video with Muse's Avatar" setting on is a video call: its encrypted audio and video go directly between the device and Meta's media server for Muse (SRTP), as in the Muse Gadget SDK; the microphone sends only while the conversation window is open. Muse's handling of information is governed by its own privacy policy and terms.

## Permissions

Bluetooth and Local Network access support pairing and discovery. Camera, microphone, location and motion access are requested separately and can be denied or revoked in iOS Settings. Pal Again continues to expose only the features allowed by the permissions you grant.

## Local network and Shortcuts

Pal Again asks before permanently allowing a Muse-requested Apple Shortcut or a local-network target. Approved items can be removed later in Settings.

## Contact and deletion requests

Pal Again has no developer-operated user-account database. For questions, bug reports, diagnostic-data deletion requests or privacy requests, write to support@exrector.com or open an issue in the [public repository](https://github.com/exrector/muse-gadget-ios/issues). **Send a Report** in Settings opens an email with the connection log, app version and device model, which you can read before sending. It never includes your chat or tokens. Do not include SDK Tokens, pairing credentials, private messages, photos or other secrets in an issue.

---

# Политика конфиденциальности Pal Again

Обновлено: 11 ноября 2026 года

Pal Again — независимый клиент с открытым исходным кодом для iOS и iPadOS. В приложении нет рекламы, поведенческой аналитики и отслеживания пользователей.

После создания пары приложение один раз спрашивает разрешение на отправку диагностики; до согласия она выключена. При согласии отправляются отчёты Apple MetricKit о сбоях и зависаниях, версия приложения и сборки, модель устройства, версия системы, язык и короткий список технических этапов работы. Они не связаны с личностью пользователя и не содержат текст чата, токены Muse, данные аккаунта, имя гаджета, имена или содержимое файлов, фото и аудио. Отправку можно отключить в настройках.

Диагностика хранится до 30 дней в размещённой в ЕС базе Cloudflare D1 и используется только для исправления ошибок. Исходные IP-адреса не сохраняются; их односторонний хеш живёт не более 48 часов исключительно для защиты приёмника отчётов от злоупотреблений.

SDK Token и данные пары хранятся в iOS Keychain. История чата и настройки остаются на устройстве; при включённой синхронизации текст чата хранится в вашем личном iCloud. Фото, голос, сообщения и запрошенные данные устройства передаются Muse только при использовании соответствующей функции. В живом разговоре ваш голос уходит Muse, пока открыто окно разговора; с настройкой «Видео с аватаром Muse» это видеозвонок, и зашифрованные звук и видео идут напрямую между устройством и медиасервером Meta для Muse, как в Muse Gadget SDK. Разрешения можно отозвать в настройках iOS, а историю, синхронизацию и пару — удалить в настройках Pal Again.

Вопросы и запросы можно отправить на support@exrector.com или оставить в [Issues репозитория](https://github.com/exrector/muse-gadget-ios/issues), не публикуя токены, данные пары, личные сообщения, фотографии и другие секреты.
