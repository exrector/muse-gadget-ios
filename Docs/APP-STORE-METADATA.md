# Pal Again — App Store metadata

## Brand

- **App name:** Pal Again
- **Tagline:** Make Old Devices Smart Again.
- **Subtitle:** AI for your older devices
- **Positioning:** Give an older iPhone or iPad a useful second life as a screen, microphone, speaker, camera and sensor companion for Muse.

The exact price is configured in App Store Connect and must not be hard-coded in public metadata because storefront prices and taxes vary by region.

## English localization

### Promotional text

Turn an older iPhone or iPad into a friendly AI companion with text and voice chat, camera, speaker and sensors—without subscriptions or ads.

### Description

Give an older iPhone or iPad a useful second life.

Pal Again turns a compatible iOS or iPadOS device into a friendly AI companion for Muse. Chat by text or voice, share photos, use the speaker, camera and sensors, and make carefully limited device actions available to your assistant.

MAKE OLD DEVICES SMART AGAIN

• A living avatar with your assistant's own face and name, moving as it listens, thinks and speaks
• Text chat with streamed responses
• Voice messages and spoken replies
• Camera and photo sharing
• Speaker, location and motion features with your permission
• Local-network discovery for supported companion services
• An explicit command allowlist—no shell access, arbitrary file access or hidden automation
• Credentials stored securely in the iOS Keychain

SIMPLE, GUIDED SETUP

Pal Again explains every step in plain language. You remain in control of Bluetooth, local-network, camera, microphone, location and motion permissions. Protected features stay unavailable until you explicitly grant access.

After pairing, your assistant's own avatar and name arrive by themselves, on this device and your others.

To pair the app, you need your own Muse Gadget SDK token and access to Muse Developer Mode on another signed-in device. Pal Again never includes or shares a common SDK token.

ONE PURCHASE, CONTINUED DEVELOPMENT

Pal Again costs $1 as a one-time paid download with no subscription and no advertising. The price pays for the ready-to-use build, Apple signing and App Store delivery, and helps fund independent development, compatibility testing on older hardware, bug fixes, future features and the Apple Developer Program, which costs about $100 per year. Thank you for helping keep useful devices in service and supporting the next version of Pal Again.

Pal Again is an independent, open-source community application. Muse and related marks belong to their respective owners. Muse service availability and SDK token access are governed by their respective terms.

### Keywords

`ai,assistant,companion,legacy,voice,chat,camera,sensors,reuse,revive`

## Russian localization

### Promotional text

Превратите старый iPhone или iPad в дружелюбного AI-компаньона с чатом, голосом, камерой, динамиком и сенсорами — без подписки и рекламы.

### Description

Подарите старому iPhone или iPad полезную вторую жизнь.

Pal Again превращает совместимое устройство с iOS или iPadOS в дружелюбного AI-компаньона для Muse. Общайтесь текстом и голосом, отправляйте фотографии, используйте динамик, камеру и сенсоры, а также предоставляйте ассистенту строго ограниченный набор действий устройства.

MAKE OLD DEVICES SMART AGAIN

• Живой аватар с лицом и именем вашего ассистента: двигается, когда слушает, думает и говорит
• Текстовый чат с потоковыми ответами
• Голосовые сообщения и озвучивание ответов
• Камера и отправка фотографий
• Динамик, геопозиция и датчики движения — только с вашего разрешения
• Поиск поддерживаемых сервисов в локальной сети
• Явный список разрешённых команд — без shell, произвольного доступа к файлам и скрытой автоматизации
• Безопасное хранение учётных данных в iOS Keychain

ПРОСТАЯ ПОШАГОВАЯ НАСТРОЙКА

Pal Again объясняет каждый шаг понятным языком. Вы сами управляете разрешениями Bluetooth, локальной сети, камеры, микрофона, геопозиции и движения. Защищённые функции недоступны, пока вы явно не разрешите их использование.

После создания пары аватар и имя вашего ассистента появятся сами, и на этом устройстве, и на остальных.

Для создания пары необходимы ваш собственный Muse Gadget SDK Token и доступ к режиму разработчика Muse на другом устройстве, где выполнен вход в аккаунт. Pal Again не содержит общего SDK Token и не передаёт его другим пользователям.

ОДНА ПОКУПКА — ДАЛЬНЕЙШЕЕ РАЗВИТИЕ

Pal Again стоит $1 и приобретается один раз: без подписки и рекламы. Цена оплачивает готовую сборку, подпись Apple и доставку через App Store, а также помогает финансировать независимую разработку, тестирование на старых устройствах, исправление ошибок, новые функции и Apple Developer Program стоимостью около $100 в год. Спасибо, что помогаете сохранять полезные устройства в работе и поддерживаете следующие версии Pal Again.

Pal Again — независимое приложение сообщества с открытым исходным кодом. Muse и связанные товарные знаки принадлежат их правообладателям. Доступность сервиса Muse и SDK Token регулируется соответствующими условиями.

### Keywords

`ассистент,компаньон,голос,чат,камера,сенсоры`

## App Review notes checklist

- Explain that this is a one-time paid download with no in-app purchases, subscription or advertising.
- Provide App Review with a valid temporary Muse test account/token or a fully functional review mode; never commit review credentials to Git.
- Describe the pairing flow and identify Muse as the external AI service used for core functionality.
- List the physical devices and OS versions tested before submission.
- Provide working support and privacy-policy URLs before review.

## Xcode mapping

- `CFBundleDisplayName`: `Pal Again`
- App icon set: `AppIcon`
- Current internal target and scheme: `MuseGadgetLegacy`
- Current bundle identifier: `com.exrector.MuseGadgetLegacy`

The internal target, scheme and bundle identifier intentionally remain unchanged during device development so an installed build keeps its Keychain credentials and pairing. App Store Connect owns the final store name and subtitle; before TestFlight, decide whether to keep the existing bundle identifier or perform one final migration to `com.exrector.palagain`.

## Artwork

The App Store icon is a 1024×1024 opaque PNG showing a loyal dog carrying a generic apple. The fruit is original artwork and does not reproduce Apple's corporate logo.
