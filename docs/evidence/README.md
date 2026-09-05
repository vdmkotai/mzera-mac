# Свидетельства проверки

Дата: 5 сентября 2026. Apple M5 Pro, 64 ГБ, macOS 26.6.2, Swift 6.3.3, FFmpeg 9.0.1. JSON не содержит имён файлов личной коллекции. Это небольшие локальные прогоны, не статистическое доказательство универсальных границ производительности.

| Файл | Сценарий |
|---|---|
| [core-benchmark.json](core-benchmark.json) | Release-сравнение прежнего компаратора и натуральных ключей на одинаковой синтетической коллекции 100k, сравнение снимков, visible() |
| [corpus-after-review.json](corpus-after-review.json) | Рекурсивный обход тестовой коллекции и по одному пробному декоду нескольких форматов, версия 0.2 |
| [animation-benchmark.json](animation-benchmark.json) | Последовательный WebP 960×540, 300 кадров, стоимость первых/последних кадров и reset |
| [ten-bit-probe.json](ten-bit-probe.json) | Реальное декодирование синтетического HEVC Main10; число кадров VideoToolbox не доказывает устройство исполнения для любого кодека |
| [gui-after-review.json](gui-after-review.json) | Окно 0.2: 75 тестовых файлов, быстрое листание, 34 измеренных показа. peakDecodeJobs включает изображения и видеоминиатюры |
| [filesystem-events.json](filesystem-events.json) | Неизменённая сверка и добавление/удаление двух временных файлов через FSEvents |
| [final-navigation-metrics.json](final-navigation-metrics.json) | Исторический выбранный событийный renderer 0.1, 26 показов |
| [direct-submit-metrics.json](direct-submit-metrics.json) | Исторический эксперимент с прямым submit, не включён в рабочую версию |
| [displaylink-metrics.json](displaylink-metrics.json) | Исторический эксперимент CAMetalDisplayLink, не включён в рабочую версию |
| [packaged-app.json](packaged-app.json) | Проверка подписи и запуска перемещённого .app: HEVC Main10, WebP 300 кадров, APNG и seek |
| [test-summary.txt](test-summary.txt) | Итог 36 тестов |
| [concurrency-warnings.txt](concurrency-warnings.txt) | Уникальные предупреждения включённой диагностики Swift 6. Не список доказанных гонок, но незавершённая проверка изоляции |

Начало метрики открытия папки находится внутри приложения, после загрузки библиотек. Она не измеряет dyld, клик по иконке или холодный запуск после перезагрузки. Метрика перехода: обработчик → presentedTime. Счётчик completedSorts не увеличивается при установке уже сохранённого порядка.

## Воспроизведение

Команды выполняются из корня репозитория. Полный test log и вспомогательные файлы находятся в игнорируемом work; важные итоги сохранены здесь.

```sh
mkdir -p work/review-audit
swift test
swiftc -O Sources/Mzera/Library.swift scripts/benchmark-core.swift -o work/review-audit/benchmark-core
work/review-audit/benchmark-core
scripts/build-app.sh
dist/Mzera.app/Contents/MacOS/Mzera --diagnose "$HOME/Pictures"
dist/Mzera.app/Contents/MacOS/Mzera --probe-video Tests/MzeraTests/Fixtures/ten-bit.mp4
dist/Mzera.app/Contents/MacOS/Mzera --probe-animation Tests/MzeraTests/Fixtures/sequential.webp
```

Коммитный WebP fixture имеет 96×64 пикселя и проверяет композицию/порядок/reset. Приведённый JSON скорости использует более крупный 960×540 файл той же длины, поэтому численные результаты команды на маленьком fixture будут другими. Генерация крупного варианта:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=960x540:rate=25:duration=12' -c:v libwebp_anim -lossless 0 -q:v 75 -loop 0 work/review-audit/long.webp
dist/Mzera.app/Contents/MacOS/Mzera --probe-animation work/review-audit/long.webp
```

Содержание кадров влияет на время декодирования. Отсутствие повторного прохода от кадра 0 обеспечивается самим последовательным API, а не только отношением двух средних значений.
