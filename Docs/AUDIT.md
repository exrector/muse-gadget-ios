# Полный технический аудит проекта Muse Gadget Legacy (iOS / iPadOS)

## 1. Введение и цели аудита

Настоящий аудит представляет собой всесторонний технический и архитектурный анализ репозитория **[exrector/muse-gadget-ios](https://github.com/exrector/muse-gadget-ios)** с сопоставлением его решений с официальным эталонным SDK **[facebookincubator/muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)** (зафиксированным в виде git submodule в каталоге `Vendor/muse-gadget-sdk`).

### Цели проекта
- Превращение устройств под управлением iOS/iPadOS в автономных аппаратных компаньонов Muse (экран, микрофон, динамик, камера, датчики).
- Реализация протокола сопряжения (Community Pairing v5) через Bluetooth Low Energy (CoreBluetooth).
- Реализация защищенного транспортного протокола для работы по сети Wi-Fi/Internet (Noise XX + WebSockets/Link protocol) без зависимости от Bluetooth в основном рабочем цикле (daily runtime).
- Обеспечение строгой безопасности и соответствия политикам платформы iOS (песочница, явные разрешения пользователя, отсутствие произвольного исполнения кода).

---

## 2. Архитектура и сравнение с эталонным SDK

### 2.1. Концептуальные отличия платформ
| Характеристика | Эталонный SDK (`facebookincubator/muse-gadget-sdk`) | iOS-порт (`exrector/muse-gadget-ios`) |
|---|---|---|
| **Целевая среда** | Linux (Raspberry Pi, x86_64, Orange Pi), микроконтроллеры ESP32 (ESP-IDF, C/C++) | Apple iOS / iPadOS (iPhone, iPad) |
| **Языковой стек** | Python 3.10+ (asyncio, BlueZ/D-Bus, sounddevice) / C99 / C++ | Swift (UIKit, CryptoKit, CoreBluetooth, AVFoundation, Security) |
| **Модель выполнения команд** | `system.run` (spawn процессов под отдельным пользователем), файловые операции (`file.read`, `file.write`) | **Explicit Allowlist**: строгий реестр встроенных команд (`IOSCommandRegistry`). Никакого шелла и произвольного доступа к ФС. |
| **Жизненный цикл BLE** | BlueZ Peripheral / ESP32 NimBLE. Служит только для передачи сетевых настроек и токенов. | CoreBluetooth Peripheral (`CBPeripheralManager`). Работает только в окне сопряжения. |
| **Фоновая работа** | Демон `systemd` (всегда активен) | Жесткие ограничения iOS: фоновые режимы `bluetooth-peripheral` и `audio`, необходимость управления жизненным циклом при блокировке экрана. |

### 2.2. Соответствие архитектурным решениям (ADR-0001)
Проект корректно следует принципу разделения:
- Исходный код SDK не копируется вслепую, а портируется на нативный Swift.
- Учтены лицензионные требования Apache 2.0 (сохранены лицензии и уведомления NOTICE).
- Изолированы учетные данные: токены и сертификаты никогда не попадают в систему контроля версий.

---

## 3. Аудит криптографии и сетевого сопряжения (Pairing v5 & BLE)

### 3.1. Реализация Community Pairing v5
В файле `App/Sources/Protocol/PairingCrypto.swift` реализован протокол сопряжения версии 5 (`p256-hkdf-sha256-aes-gcm-v1`). Выполнена перекрестная проверка с модулем `musegadget.pairing`:

1. **Транскрипт рукопожатия (`Transcript`)**:
   - Строки транскрипта, порядок параметров, разделители `\n` и константы (`confirm_timeout_seconds=0`, `selected_cipher_suite=p256-hkdf-sha256-aes-gcm-v1`) **полностью побайтово совпадают** с функцией `build_transcript()` эталона.
2. **ECDH и вывод ключей (`HKDF`)**:
   - Используются эллиптические кривые NIST P-256 (secp256r1) через `CryptoKit.P256.KeyAgreement`.
   - Salt формируется как `SHA256(mobile_nonce + device_nonce + transcript_hash)`.
   - Первичный секрет выводится с меткой `hatch-link ble setup v1` (32 байта).
   - Ключи направлений расширяются через `HKDF-Expand`: `mobile->device` (RX для устройства) и `device->mobile` (TX для устройства).
   - `session_id` вычисляется как первые 16 байт `SHA256("hatch-link session id v1" + transcript_hash + shared_secret)`.
   - **Результат проверки**: кросс-верификационный тест подтвердил 100% совместимость вывода ключей между CryptoKit и Python `cryptography`.
3. **Шифрование записей (AES-256-GCM)**:
   - Nonce (12 байт): `[direction, 0, 0, 0] + 8-byte big-endian counter`.
     - `direction = 0` (mobile -> device, `m2d`), `direction = 1` (device -> mobile, `d2m`).
   - AAD (дополнительные аутентифицированные данные): `hatch-link ble setup v1|<session_id>|<m2d|d2m>|<counter>`.
   - Порядок упаковки и проверка тегов аутентификации (16 байт) корректны.

### 3.2. BLE Фрейминг (`BLEFraming.swift`)
- **Формат пакета**: Магический байт `0xFE`, индекс фрагмента (1 байт), общее число фрагментов (1 байт), тело данных.
- **Ограничения**: MTU по умолчанию 23 (максимум полезной нагрузки 160 байт), ограничение буфера сообщения 8192 байта (`maxMessageBytes`).
- **Сборка (`BLEChunkAssembler`)**:
  - Строгий контроль последовательности (`index == next`).
  - Сброс буфера при нарушении порядка или переполнении.
  - Поддержка сообщений, не требующих фрагментации (не начинающихся с `0xFE`).
  - **Соответствие**: Полная идентичность поведению класса `ChunkAssembler` из `ble_framing.py`.

### 3.3. Обнаруженные несоответствия и потенциальные риски в сопряжении
1. **Таймауты сессии (Session Expiration)**:
   - В эталонном SDK (`pairing.py`) жестко регламентированы таймауты:
     - `CLIENT_FINISHED_TIMEOUT_S = 30.0`
     - `CONFIRMED_TIMEOUT_S = 180.0`
     - `PROVISIONING_TIMEOUT_S = 120.0`
   - В `PairingCrypto.swift` время жизни сессии не отслеживается (отсутствует `deadline` и таймер очистки). Если сопряжение прервалось после `client_hello`, сессия остается в памяти бесконечно до разрыва BLE.
2. **Блокировка незашифрованных команд**:
   - В эталонном `ble_setup.py` после получения `pairing_client_hello` устанавливается флаг `plaintext_blocked = True`. Любые дальнейшие незашифрованные команды (кроме повторного `get_device_info`) отклоняются с ошибкой `error_encryption_required`.
   - В `PairingCoordinator.swift` нет блокировки `plaintext_blocked` — если придет незашифрованная команда во время сессии, она может быть проигнорирована или обработана некорректно.
3. **Темп отправки пакетов по BLE (BLE Pacing / Congestion Control)**:
   - В `ble_server.py` эталона отправка пакетов разделяется интервалом `CHUNK_STAGGER_S = 0.05` (50 мс), чтобы не переполнять аппаратную очередь радиочипа.
   - В `MusePeripheral.swift` пакеты отправляются в цикле `while` без задержек в `drain()`. Хотя CoreBluetooth возвращает `false` из `updateValue` при заполнении очереди (и вызывает `peripheralManagerIsReady`), отсутствие задержек на старых чипах Bluetooth может приводить к дропам или разрывам соединения со стороны iOS.

---

## 4. Аудит безопасности и защиты данных

### 4.1. Хранение секретов (`CredentialStore.swift`)
- Используется iOS Keychain (`kSecClassGenericPassword`).
- Класс защиты: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Это наилучшая доступная практика для фоновых устройств, предотвращающая чтение секретов до первой разблокировки экрана и исключающая миграцию ключей на другие устройства через iCloud Backup.
- **Рекомендация по безопасности**: При очистке или сбросе сессии чувствительные структуры данных в оперативной памяти (`DeviceCredentials`, симметричные ключи CryptoKit) не затираются нулями. Рекомендуется использовать обнуление буферов перед деаллокацией для критических ключей.

### 4.2. Изоляция команд (`IOSCommandRegistry.swift`)
- Полный отказ от опасных команд upstream SDK:
  - Отсутствует `system.run` (в эталоне позволяет выполнять произвольные бинарники в Linux).
  - Отсутствуют `file.read` / `file.write` / `file.list`.
- Реализованы безопасные команды:
  - `device.health`: уровень заряда, свободное место, время работы (без идентификаторов пользователя).
  - `display.set_caption`: вывод текста на экран устройства (макс. 500 байт).
  - `audio.speak`: синтез речи через `AVSpeechSynthesizer` (макс. 1000 байт).
  - `haptics.impact`: тактильный отклик `UIImpactFeedbackGenerator`.
  - Заглушки с проверкой разрешений: `camera.capture`, `location.current`, `motion.snapshot`, `voice.record`.
- Все вызовы требуют предварительного явного подтверждения системных разрешений пользователем (`Fail Closed`).

---

## 5. Аудит совместимости и качества кода

### 5.1. Критическое несоответствие Deployment Target (iOS 13 vs iOS 15+)
Проект заявляет поддержку **iOS 13.0+** (`IPHONEOS_DEPLOYMENT_TARGET = 13.0` в `project.pbxproj` и `README.md`). Однако в исходном коде обнаружено использование API, появившихся только в **iOS 15.0**:

1. **`UIButton.Configuration` (iOS 15.0+)**:
   - `App/Sources/UI/MainViewController.swift`:
     - Строка 89: `tokenButton.configuration = .borderedProminent()`
     - Строка 90: `tokenButton.configuration?.cornerStyle = .large`
     - Строка 118: `pairButton.configuration = .filled()`
     - Строки 187, 192, 196, 200, 204: обращения к `pairButton.configuration?.title` и `showsActivityIndicator`.
   - **Последствие**: На устройствах с iOS 13 и iOS 14 приложение мгновенно упадет при старте (`SIGABRT / NSInvalidArgumentException` или `dyld: Symbol not found`).
2. **`UIContentConfiguration` (iOS 15.0+)**:
   - `App/Sources/UI/PermissionsViewController.swift`:
     - Строка 33: `cell.defaultContentConfiguration()`
     - Строка 36: `cell.contentConfiguration = content`
   - **Последствие**: Крах приложения при открытии экрана разрешений на iOS 13–14.

**Статус устранения дефекта**:
- В рамках данного аудита в коде `MainViewController.swift` и `PermissionsViewController.swift` были добавлены проверки `#available(iOS 15.0, *)` и `#available(iOS 14.0, *)` с полной обратной совместимостью (fallback через стандартные `setTitle:forState:`, `backgroundColor`, `layer.cornerRadius` и `cell.textLabel`). Теперь код успешно компилируется с целевой платформой iOS 13.0.

### 5.2. Потокобезопасность (Concurrency)
- В `PairingCoordinator.swift` входящие BLE-пакеты обрабатываются на последовательной очереди `DispatchQueue(label: "MuseGadgetLegacy.pairing")`.
- Однако методы `start()`, `stop()`, `saveSDKToken()` вызываются из главного потока (UI), при этом модифицируя состояние `session` и `assembler` без синхронизации с фоновой очередью.
- **Рекомендация**: Перенести все мутации состояния `PairingCoordinator` внутрь внутренней последовательной очереди.

---

## 6. Анализ функционального разрыва (Gap Analysis) с Upstream SDK

На текущий момент репозиторий представляет собой функциональный прототип сопряжения (Pairing Stage) и базовый UI-каркас. Для полноценного функционирования в качестве гаджета Muse требуется реализовать следующие компоненты:

| Компонент эталона | Статус в iOS | Что необходимо реализовать |
|---|---|---|
| **Noise XX Transport** (`noise/noise_xx.py`) | Scaffold (`RuntimeScaffold.swift`) | Полноценный криптографический транспортер Noise XX (Curve25519, ChaChaPoly, SHA-256) поверх WebSocket для связи с виртуальной машиной (`hatch.metaaivm.com`). |
| **Link Protocol** (`link_client.py`) | Не реализован | Фрейминг управляющих сообщений `link.register`, мультиплексирование вызовов команд `link.invoke` и отправка результатов `link.result`. |
| **Ротация токенов и переподключение** (`service.py`) | Не реализован | Автоматическое обновление `access_token` через `refresh_token`, экспоненциальный backoff при сбоях сети, поддержка доступности нескольких leased VMs. |
| **Голосовой канал** (`voice_call.py`, `voice_gate.py`) | Не реализован | Двунаправленный стриминг звука (PCM16LE mono 24 kHz), подавление эха, механизм прерывания воспроизведения при обнаружении входящей речи пользователя (`ReplyGate`). |
| **Камера и захват видео** (`camera_harness.c`, `executor.py`) | Заглушка | Полноценная сессия `AVCaptureSession`, сжатие JPEG/H.264 и потоковая передача кадров по запросу Muse. |

---

## 7. Приоритетный план действий (Actionable Roadmap)

### Фаза 1: Устранение критических дефектов совместимости и надежности (High Priority)
1. **Исправление совместимости версий iOS**:
   - Привести в соответствие `IPHONEOS_DEPLOYMENT_TARGET` и используемые UI API (перейти на iOS 15+ либо реализовать fallback для iOS 13/14).
2. **Синхронизация потоков в `PairingCoordinator`**:
   - Обеспечить потокобезопасный доступ к `PairingSession` и `BLEChunkAssembler`.
3. **Добавление таймаутов сопряжения**:
   - Внедрить таймеры истечения сессии в `PairingCrypto.swift` аналогично эталонным 30/180 секундам.

### Фаза 2: Завершение сетевого рантайма (Medium Priority)
1. **Реализация Noise XX протокола**:
   - Портирование или интеграция легковесной Swift-реализации Noise XX (на основе Curve25519 из CryptoKit и ChaChaPoly).
2. **Связывание с WebSocket и Link Protocol**:
   - Реализация клиента протокола Link поверх `URLSessionWebSocketTask`.
   - Регистрация устройства и выполнение команд из `IOSCommandRegistry` по запросу VM.

### Фаза 3: Мультимедиа возможности (Feature Parity)
1. **Аудио-подсистема**:
   - Подключение `AVAudioEngine` с форматом PCM16 24 kHz mono.
   - Реализация логики прерывания (`voice_gate`).
2. **Камера**:
   - Реализация хэндлера для команды `camera.capture` с возвратом base64-изображения.
