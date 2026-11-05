Провёл полный аудит по четырём слоям: актуальный официальный SDK, код Pal Again, тесты и фактические проверки на устройствах. Главный итог: ядро Pal Again уже полноценное, но до функционального паритета с лучшими возможностями SDK не хватает прежде всего realtime voice, серверной истории чата, озвученных ответов Muse, отмены ответа и более широких локальных интеграций.

Аватар не сбрасывал, не заменял и вообще не вызывал ни одной avatar-команды.

## Что именно считается официальным SDK

У Muse сейчас фактически два полноценных gadget runtime:

| Платформа | Реальное назначение |
|---|---|
| ESP32 | Самостоятельный физический гаджет: экран, локальный аватар, кнопки, микрофон, камера, датчики, BLE, OTA |
| Linux | Home Link/Home Hub: Raspberry Pi, мини-компьютеры и обычный Linux |
| Raspberry Pi | Не отдельный протокол — это Linux SDK с особенностями установки |
| iOS/Android в официальном репозитории | Не gadget runtime. Это тестовые приложения для передачи видео с телефона на ESP32 по локальной сети |
| Web Flasher | Прошивка и настройка ESP32, не отдельная runtime-платформа |

То есть Pal Again — это действительно самостоятельный перенос gadget runtime на iOS, а не доработка официального iOS-примера.

Аудит сделан по свежему upstream `270e653` от 3 ноября 2026 года, а не только по локальной копии. Локальный submodule действительно правильно закреплён на `4a857e3`, но отстаёт от текущего upstream на:

- 44 коммита;
- 198 изменённых файлов;
- около 29 900 добавленных строк.

Среди пропущенных upstream-изменений уже есть realtime voice improvements, полноэкранные ответы, размер текста, навигация по предыдущим ответам, новые камеры, датчики и новые платы. Это не означает, что submodule надо механически обновить: сначала следует разобрать эти 44 коммита и перенести только относящееся к Pal Again.

## Что официально умеет Linux SDK

Linux/Home Link предоставляет:

- BLE pairing v5;
- Noise XX и `link.register`;
- автоматический reconnect и обновление VM credential;
- текстовые сообщения;
- изображения;
- голосовые заметки;
- подписку на ответы `/chat/subscribe`;
- отдельные side chats через `session_id`;
- получение MP3-озвучки ответа через `stream_tts(message_id)`;
- realtime voice через `/voice/realtime` и `/voice/end-call`;
- получение серверной истории `/chat/history`;
- VM-файлы через `/fs/read` и `/fs/write`;
- собственные расширяемые команды из `commands.d`;
- базовые команды:
  - `system.run`;
  - `file.read`;
  - `file.write`;
  - `device.health`.

`system.run` и произвольные файловые команды для iOS переносить нельзя: это не упущение Pal Again, а правильное ограничение sandbox и безопасности.

Именно отсюда происходят многие демонстрации «Disk Doctor», управления сервером, умным домом, телевизорами, Home Assistant и другими устройствами. В Linux они в основном опираются на shell, утилиты, MQTT, WebSocket, SSDP, SSH и пользовательские команды.

## Что официально умеет ESP32 SDK

Всегда доступна:

- `device.health`.

В зависимости от конкретной платы и её конфигурации могут регистрироваться:

- `device.discover`;
- `display.draw_url`;
- `display.draw_file`;
- `display.show_animation`;
- `voice.configure`;
- `sensors.read`;
- `camera.capture`;
- `device.ota`;
- BLE-набор:
  - `ble.state`;
  - `ble.power`;
  - `ble.advertise`;
  - `ble.scan`;
  - `ble.connect`;
  - `ble.disconnect`;
  - `ble.discover`;
  - `ble.read`;
  - `ble.write`;
  - `ble.subscribe`.

Полноэкранные ESP32-платы дополнительно имеют:

- локально отрисовываемый анимированный аватар;
- состояния idle/listening/thinking/speaking;
- push-to-talk;
- голосовые заметки;
- изображения;
- полноэкранный текст ответа;
- размер текста;
- навигацию по последним ответам;
- настройки яркости, сна, громкости и усиления микрофона;
- realtime voice на подходящих аудиоплатах;
- некоторые аппаратные датчики;
- иногда камеру и BLE central.

Важно: официальный ESP32-аватар — локальная прошивка и ассеты. Облачного API, который автоматически отдаёт Pal Again профильную картинку аккаунта, в зарегистрированном протоколе я не обнаружил. Реализованная в Pal Again загрузка аватара из VM — собственное расширение приложения, причём более гибкое, чем базовый ESP32-рендерер.

## Что реально реализовано в Pal Again

В [IOSCommandRegistry.swift](/Users/exrector/Documents/PROJECTS/muse-gadget-ios/App/Sources/Commands/IOSCommandRegistry.swift:78) сейчас зарегистрированы 23 команды:

| Группа | Команды |
|---|---|
| Состояние | `device.health` |
| Экран | `display.set_caption`, `display.set_brightness`, `display.show_card`, `display.clear_card`, `display.draw_file`, `display.clear_image` |
| Аватар | `display.set_avatar`, `display.set_name`, `display.play_avatar`, `display.clear_avatar` |
| Звук | `audio.speak`, `voice.configure`, `voice.record` |
| Устройство | `haptics.impact`, `torch.set`, `camera.capture`, `location.current`, `motion.snapshot` |
| Shortcuts | `shortcuts.run`, `shortcuts.list` |
| Локальная сеть | `lan.discover`, `lan.request` |

Кроме команд реализованы:

- BLE pairing v5;
- Noise XX;
- VM discovery;
- token rotation;
- reconnect;
- `link.register`, `link.invoke`, `link.result`;
- текстовый чат;
- фотографии;
- WAV-голосовые заметки;
- локальная история;
- iCloud KVS-синхронизация текста;
- peer sync по локальной сети;
- VM-файлы для изображений и аватаров;
- H.264-аватарные состояния;
- закреплённые карточки info/timer/progress;
- разрешения и локальные подтверждения опасных действий;
- TLS TOFU для локальных HTTP(S)-устройств;
- поддержка iOS 15.

## Что подтверждено на настоящих устройствах

| Возможность | Состояние |
|---|---|
| Pairing, Noise, регистрация | Подтверждено |
| Текстовый чат | Подтверждено |
| Фото и голосовые заметки | Подтверждено |
| `haptics.impact` | Подтверждено на iPhone 6s |
| `torch.set` | Подтверждено на iPhone 6s; корректно недоступно на iPad |
| `display.show_card` | Таймер подтверждён, включая восстановление |
| `display.draw_file` | Подтверждено на iPad |
| `audio.speak` | Подтверждено на iPad |
| `shortcuts.run` | Базовая работа подтверждена на iPhone 6s |
| `motion.snapshot` | Теперь подтверждено на iPad: в чате видны реальные acceleration, rotation, attitude и gravity |
| Аватар и четыре состояния | Ранее подтверждено на обоих устройствах; в этом аудите не трогал |
| iCloud history sync | Частично подтверждено |
| Background reconnect | Измерено: iOS при обычном background приостанавливает приложение примерно через 30–37 секунд |

Новую команду в чат я не посылал: существующий разговор на iPad уже содержал достаточное физическое подтверждение `motion.snapshot`. Поэтому не было смысла лишний раз тревожить рабочее устройство.

## Команды, которые есть в коде, но всё ещё не подтверждены полноценно

Отдельного живого E2E ещё требуют:

- `device.health`;
- `display.set_caption`;
- `display.set_brightness`;
- `display.clear_card`;
- `display.set_name`;
- прямой вызов `display.play_avatar`;
- `display.clear_image`;
- `voice.configure`;
- `shortcuts.list`;
- полное получение результата `shortcuts.run`;
- `lan.discover`;
- `lan.request`;
- `camera.capture`;
- `location.current`;
- удалённый `voice.record`.

`display.clear_avatar` проверять нельзя и не нужно.

Документ [PROTOCOL-STATUS.md](/Users/exrector/Documents/PROJECTS/muse-gadget-ios/Docs/PROTOCOL-STATUS.md:16) уже немного отстал от реальности: там motion всё ещё обозначен как «awaiting live check», хотя на iPad он фактически подтверждён. Аналогично pairing v5 уже подтверждён успешным живым `auth_ok`, а не только реализацией.

## Главные недостающие возможности

### 1. Realtime voice

Это крупнейший функциональный разрыв.

Сейчас голос в Pal Again — запись WAV и отправка как сообщения. В актуальном Linux и ESP32 SDK есть отдельный живой голосовой канал:

- `/voice/realtime`;
- `/voice/end-call`;
- streaming audio;
- half/full duplex;
- barge-in;
- captions;
- управляемое завершение звонка.

Для ощущения настоящего AI-компаньона это важнее большинства новых команд.

### 2. Озвученные ответы Muse

В [MuseRuntime.swift](/Users/exrector/Documents/PROJECTS/muse-gadget-ios/App/Sources/Protocol/MuseRuntime.swift:330) запросы жёстко отправляются с `output_modality: "text"`.

Есть локальная `audio.speak`, но это не то же самое, что официальный `stream_tts(message_id)`:

- `audio.speak` использует системный голос iOS;
- `stream_tts` получает подготовленную сервером MP3-озвучку конкретного ответа Muse.

Следует поддержать оба режима и дать пользователю выбор.

### 3. Серверная история `/chat/history`

Pal Again хранит историю локально и синхронизирует её собственными средствами. Но актуальный SDK уже имеет `/chat/history`.

Это позволит:

- восстановить сообщения после переустановки;
- видеть ответы, полученные другим клиентом;
- синхронизировать реальное состояние Muse, а не только локальные копии;
- избежать расхождений между устройствами.

### 4. Остановка ответа

Нет пользовательской кнопки Stop/Cancel. Нужны:

- отмена текущего HTTP/stream-запроса;
- прекращение локального отображения токенов;
- корректное завершение подписки;
- отдельное поведение для realtime voice.

Это заметный UX-пробел для чата.

### 5. Side chats и `session_id`

Парсер `session_id` частично присутствует, но отправка сообщений работает только с основным чатом. Linux SDK умеет открывать и продолжать боковые сессии.

Это пригодится для:

- отдельных задач;
- таймеров и длительных операций;
- диалогов конкретного виджета;
- предотвращения засорения главного чата.

### 6. Расширенный `device.health`

Сейчас возвращаются только:

- system;
- system version;
- generic model;
- battery percentage.

Стоит добавить безопасные показатели:

- charging state;
- battery state;
- thermal state;
- low-power mode;
- свободное дисковое пространство приложения/контейнера;
- яркость;
- app version/build;
- connection uptime;
- время последнего ping;
- foreground/background;
- состояние камеры, микрофона, location и Bluetooth permissions.

Это даст Muse реальную диагностику гаджета без попытки имитировать Linux Disk Doctor.

### 7. Работа с VM-файлами

Сейчас есть специальное чтение `/fs/raw` для картинок и аватара. Нет общего безопасного аналога `/fs/read` и `/fs/write`.

Правильный вариант для iOS:

- не открывать произвольную файловую систему телефона;
- предоставить отдельный sandbox `Pal Again Documents`;
- ограничить размер, расширения и директории;
- разрешить обмен документами, карточками, изображениями и результатами команд.

### 8. Локальные устройства

Текущий `lan.discover` — в основном Bonjour. Официальный ESP32 `device.discover` шире и использует ARP, mDNS, SSDP, SNMP и NetBIOS.

Для полезной интеграции умного дома Pal нужны отдельные безопасные адаптеры:

- SSDP/UPnP;
- WebSocket;
- MQTT;
- возможно UDP discovery;
- Home Assistant;
- Hue;
- Sonos;
- Chromecast;
- локальные телевизоры.

Не следует добавлять универсальный shell или SSH-команду. Лучше ограниченные протокольные адаптеры плюс Shortcuts.

### 9. BLE central

ESP32 может сканировать и управлять BLE-устройствами. iOS технически тоже может реализовать большую часть этого через CoreBluetooth:

- scan;
- connect;
- services/characteristics discovery;
- read/write;
- subscribe.

Ограничения iOS:

- нельзя программно включать Bluetooth;
- нельзя полагаться на MAC-адреса;
- нужны UUID и пользовательское разрешение;
- фоновые сценарии ограничены;
- удалённый доступ должен быть allowlisted.

Это полезная, но не первая по приоритету функция.

### 10. Phone-to-ESP32 video

Официальные iOS/Android-примеры умеют передавать:

- камеру;
- color bars;
- тестовые видео;
- H.264 или VP8;
- по локальному TCP с mDNS.

Это можно добавить в Pal Again как отдельный режим «показать камеру телефона на ESP32-гаджете». Но это соседняя функция, а не часть основного Muse-чата.

## Что переносить не нужно

| Возможность SDK | Решение для Pal Again |
|---|---|
| `system.run` | Не добавлять |
| Произвольные `file.read/file.write` по iOS filesystem | Не добавлять |
| `device.ota` | Никогда не регистрировать: это ESP32 OTA |
| `display.draw_url` | Текущий `draw_file` безопаснее; URL-вариант создаёт SSRF-риск |
| ESP32 environmental `sensors.read` | Только если появляется соответствующее внешнее оборудование |
| ESP32 source-built avatar renderer | Не нужен: у Pal уже собственная VM/MP4-система |
| Регистрация как `device_family: link` | Не делать; `homehub` правильно для не-ESP32 клиента |

## Критическая проблема с аватаром

Новое правило пользователя сейчас не соблюдается самим приложением:

- [IOSCommandRegistry.swift](/Users/exrector/Documents/PROJECTS/muse-gadget-ios/App/Sources/Commands/IOSCommandRegistry.swift:243) рекламирует удалённую команду `display.clear_avatar`;
- она немедленно вызывает `images.clearAvatar()` без локального подтверждения;
- [MuseAppView.swift](/Users/exrector/Documents/PROJECTS/muse-gadget-ios/App/Sources/UI/MuseAppView.swift:2357) содержит кнопку «Убрать аватар».

То есть аватар можно случайно удалить либо через Muse, либо через настройки. Согласно вашему правилу, правильное решение — полностью убрать из Pal Again:

- регистрацию `display.clear_avatar`;
- обработчик;
- кнопку удаления;
- упоминание команды в пользовательской документации.

Само хранилище можно оставить без изменений, чтобы не рисковать существующими файлами.

## Ограничение работы в фоне

Это не забытая функция, а ограничение iOS. [AppEnvironment.swift](/Users/exrector/Documents/PROJECTS/muse-gadget-ios/App/Sources/Application/AppEnvironment.swift:11) запрашивает примерно 30 секунд дополнительного времени, после чего iOS приостанавливает приложение.

Ранее на iPad было измерено:

- последний ping примерно на 20-й секунде;
- background time закончился примерно на 32-й;
- приложение было остановлено примерно на 37-й;
- после возвращения регистрация восстанавливалась примерно за 5 секунд.

Поэтому Pal Again может быть постоянно подключён только при открытом приложении и активном экране. Обход через неслышимое аудио или фиктивный Picture in Picture для App Store использовать нельзя.

## Состояние тестов

Полный тестовый прогон завершён:

- 76 тестов;
- 76 успешно;
- 0 ошибок;
- 0 пропущено;
- iPhone 16 Pro Simulator, iOS 18.6.

Также отдельно прошли:

- pairing v5 smoke;
- BLE framing smoke, 10 frames.

Остались предупреждения:

- три Swift-предупреждения про смешанный implicit strong/weak capture в `MuseChatPeerSync`, `MuseChatStore` и `MuseAppView`;
- linker warnings из-за tests deployment target iOS 15 и более нового XCTest;
- один runtime warning о возможной QoS priority inversion.

Они не сломали тесты, но перед релизом их лучше убрать.

## Рекомендуемый порядок развития

1. Убрать все способы очистки аватара.
2. Обновить status-документацию по уже подтверждённым функциям.
3. Добавить `/chat/history` и reconciliation с локальной историей.
4. Добавить Stop/Cancel.
5. Расширить `device.health`.
6. Добавить `stream_tts` и режим озвученных ответов.
7. Реализовать realtime voice отдельной фазой.
8. Добавить side chats.
9. Создать безопасный sandbox для VM-документов.
10. Расширять LAN-интеграции и затем BLE central.
11. Phone-to-ESP32 video оставить отдельным дополнительным модулем.

Код репозитория во время аудита я не менял. Рабочее дерево содержит только уже существующую незатреканную папку `screens/`.

<oai-mem-citation>
<citation_entries>
MEMORY.md:35-50|note=[canonical project device history and verification boundaries]
rollout_summaries/2026-11-03T17-31-16-VXWi-muse_gadget_ios_chat_history_icloud_voice_mode.md:14-38|note=[physical devices runtime commands and confirmed vibration]
rollout_summaries/2026-11-03T17-31-16-VXWi-muse_gadget_ios_chat_history_icloud_voice_mode.md:44-65|note=[chat persistence iCloud sync and verification status]
extensions/ad_hoc/notes/2026-11-05-pal-again-avatar-safety.md:1-6|note=[permanent avatar safety rule for this project]
</citation_entries>
<rollout_ids>
01a1a277-1746-7922-86e6-4a0eebfb05f2
</rollout_ids>
</oai-mem-citation>
