#!/usr/bin/env python3
"""Writes the project pages for GitHub Pages: site/index.html and site/apps/index.html (English), site/ru/… (Russian).

    python3 Scripts/site/build.py

The texts are below; the numbers come from the repository itself: the app version from project.yml, the rules and
apps counts, the database version and the list of apps from App/Resources/database.sqlite (rounded down: 6370 → 6,300+).
Icons of the apps are site/img/apps/<bundle id>.webp (a letter tile when there is none). Run it after changing any of
them and commit site/. The pages are plain HTML and CSS (site/style.css); the apps page has a few lines of script for
its search box. .github/workflows/pages.yml publishes the folder.
"""
import html
import pathlib
import re
import sqlite3

ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "site"


def project_value(key):
    match = re.search(rf"^\s*{key}:\s*\"?([^\"\n]+)\"?\s*$", (ROOT / "project.yml").read_text(), re.M)
    return match.group(1).strip() if match else ""


REPO = project_value("MW_REPOSITORY")
VERSION = project_value("MARKETING_VERSION")
GITHUB = f"https://github.com/{REPO}"
DOWNLOAD = f"{GITHUB}/releases/latest/download/MacWashing.dmg"

db = sqlite3.connect(ROOT / "App" / "Resources" / "database.sqlite")
RULES = db.execute("SELECT count(*) FROM rules").fetchone()[0]
APPS = db.execute("SELECT count(*) FROM apps").fetchone()[0]
DB_VERSION = db.execute("SELECT value FROM info WHERE key = 'version'").fetchone()[0]
db.close()


def rounded(n, sep):
    """Down to the first two digits: 6370 → 6,300+; 938 → 930+."""
    digits = len(str(n))
    step = 10 ** max(digits - 2, 0)
    value = n // step * step
    text = f"{value:,}".replace(",", sep)
    return text + "+"


def icon_name(bundle_id):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", bundle_id)


def load_apps():
    """The apps of the database by name: name, bundle id, number of rules, icon file (or None), sorted by name."""
    db = sqlite3.connect(ROOT / "App" / "Resources" / "database.sqlite")
    rows = db.execute("""SELECT a.name, a.bundle_id, count(ar.rule_id) FROM apps a
                         LEFT JOIN app_rules ar ON ar.app_id = a.id GROUP BY a.id""").fetchall()
    db.close()
    merged = {}   # one tile per name: helpers and editions of the same name add up
    for name, bundle_id, rules in rows:
        icon = f"{icon_name(bundle_id)}.webp"
        icon = icon if (SITE / "img" / "apps" / icon).exists() else None
        old = merged.get(name.casefold())
        if old:
            merged[name.casefold()] = (old[0], old[1], old[2] + rules, old[3] or icon)
        else:
            merged[name.casefold()] = (name, bundle_id, rules, icon)
    return sorted(merged.values(), key=lambda a: (a[0].casefold(), a[1]))


ALL_APPS = load_apps()
TONES = ["junk", "large", "uninstaller", "disk", "privacy"]


def tile_icon(prefix, name, bundle_id, icon, size):
    if icon:
        return f'<img src="{prefix}img/apps/{icon}" width="{size}" height="{size}" alt="" loading="lazy" decoding="async">'
    tone = TONES[sum(map(ord, bundle_id)) % len(TONES)]
    letter = next((c for c in name if c.isalnum()), "?").upper()
    return f'<span class="letter tone-{tone}" aria-hidden="true">{e(letter)}</span>'


DOWNLOAD_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19.5h14"/></svg>'
GITHUB_ICON = '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>'

T = {
    "en": {
        "lang": "en",
        "title": "MacWashing — a careful Mac cleaner and uninstaller, free and open source",
        "description": "MacWashing clears cache and junk, uninstalls apps completely, finds large files and shows what takes up space on your Mac. Free and open source.",
        "nav": ["Features", "Rules database", "Safety", "FAQ"],
        "other_lang": ("Русский", "ru/"),
        "titleA": "Give your Mac a deep clean",
        "titleB": "Free and open source",
        "lead": "MacWashing keeps your Mac healthy and brings back its youth: it clears cache and junk, helps you find large files and free up disk space. Taking care of your Mac is what MacWashing is here for.",
        "download": "Download for Mac",
        "source": "View on GitHub",
        "meta": f"Version <b>{VERSION}</b> · macOS 14 Sonoma or later · GPL-3.0 · no account, no limits",
        "shot_alt": "MacWashing, System Junk: app caches of Spotify, Telegram, Chrome and other apps found, 72.84 GB ready to be cleaned",
        "stats": [(rounded(RULES, ","), "cleaning rules"), (rounded(APPS, ","), "apps in the rules database"), ("5", "tools in one window"), ("12", "interface languages")],
        "junk": {
            "kicker": "System Junk",
            "title": "Clear cache, logs and leftovers on your Mac",
            "text": "Finds everything that can go without harming your system, including much of System Data: user and system caches, app logs, leftovers of apps you removed long ago, forgotten installers and gigabytes of Xcode junk.",
            "points": [
                "Xcode DerivedData, old iOS DeviceSupport files and simulators Xcode no longer uses",
                "Caches of browsers and apps: Chrome, Edge, Brave, Opera, Slack, Discord, Notion, Figma, VS Code, Cursor, ChatGPT, Claude, Obsidian, Dropbox and more",
                "Broken preference files and login items of deleted apps",
                "Expand any category and uncheck whatever you want to keep",
            ],
            "bento": [
                ("User Cache", "App caches grow to tens of gigabytes."),
                ("Xcode Junk", "Xcode DerivedData, debugging data for old iOS versions and simulator caches."),
                ("Editor Junk", "Caches of Final Cut Pro, Premiere Pro, Lightroom and more."),
                ("Installers", "Disk images and packages forgotten in Downloads."),
                ("App Leftovers", "Settings and caches of apps that are no longer on your Mac."),
                ("Logs", "From apps and the system: nothing needs them to work."),
                ("Old Project Leftovers", "node_modules, Pods, .venv and other dependencies in projects you haven’t opened for over 90 days."),
            ],
        },
        "editors": {
            "kicker": "For photographers and videographers",
            "title": "Get your space back after editing and shooting",
            "text": "The Final Cut Pro and Premiere Pro cache, Lightroom previews and the DaVinci Resolve cache take tens of gigabytes on an active project. Your photos, videos and projects stay where they are.",
            "apps": "Final Cut Pro · Premiere Pro · Lightroom Classic · DaVinci Resolve · iMovie",
        },
        "uninstaller": {
            "kicker": "Uninstaller",
            "title": "Uninstall apps on Mac completely",
            "text": "Dragging an app to the Trash doesn’t uninstall it completely: its settings, caches and background items stay behind. The Uninstaller finds them and removes everything together.",
            "points": [
                "Sort by size, name or last launch, and “Select Unused” picks the apps you haven’t opened in ages",
                "Remove several apps at once, or just individual folders inside one",
                "Removes apps installed with Homebrew and command-line tools too",
                "A component shared by several apps goes only together with all of them",
            ],
            "alt": "Uninstaller: a list of apps sorted by size with when each was last opened, Google Chrome selected with its app and cache sizes",
        },
        "large": {
            "kicker": "Large Files",
            "title": "Find large files you forgot about",
            "text": "Videos, archives and disk images you downloaded once and never opened again. MacWashing helps you find large, long-forgotten files on the disks you choose, and then you decide their fate.",
            "points": ["Search whole disks or only the folders you pick", "Finds even what’s tucked away", "You decide what to do with what it finds"],
            "alt": "Large Files: files grouped by type, size and last opened date, with videos, Xcode and Linux images at the top",
        },
        "disk": {
            "kicker": "Storage",
            "title": "See what’s taking up space on your Mac",
            "text": "A Finder-style browser that shows the real size of every folder. Walk through your home folder, iCloud Drive, the Trash and every disk, and clear out what you no longer need.",
            "points": ["Helps you find what’s really taking up space on your disk", "Then free up space in one click", "Made a mistake? Just put the file back from the Trash"],
            "alt": "Storage: the home folder with the size of every folder, Library and Applications being the largest",
        },
        "privacy": {
            "kicker": "Privacy",
            "title": "Who can use your camera, screen and files",
            "text": "Shows which apps you let use the camera, microphone, screen recording, files, automation and every other macOS permission — and takes access back from the ones that don’t need it.",
            "chips": ["Camera", "Microphone", "Screen Recording", "Full Disk Access", "Automation", "Accessibility", "Input Monitoring", "Files & Folders", "Contacts", "Calendars", "Photos"],
            "alt": "Privacy: permission categories with the number of apps in each, Camera selected with five apps and a Revoke button for each",
        },
        "more": {
            "kicker": "And a few more things",
            "title": "You’ll ask — MacWashing already does it",
            "items": [
                ("When I delete a messenger, can I wipe the chat history and accounts too?", "Yes. The Uninstaller lists **chats and accounts** as separate items: check the ones you want gone and they go with the app. Leave them unchecked and they stay, in case you install the messenger again."),
                ("Why not just drag the app to the Trash?", "That takes only the app itself. MacWashing **cleans deeper**: its caches, settings, logs and background items go too, even from folders shared by everyone on the Mac."),
                ("What if there’s something I need among the junk?", "It all goes **by your rules**. You can review every find and uncheck it, send removed files to the Trash, keep confirmation on and add your work folders to Exclusions — no scan ever looks inside."),
                ("Do I have to clean it myself every time? Is there auto-clean?", "There is **auto-clean**, you turn it on in Settings. Once it is on, daily, weekly or monthly MacWashing removes the same junk in the background and sends a notification. Apps you have open are skipped."),
            ],
        },
        "db": {
            "kicker": "The rules database",
            "title": "Every rule is checked on a real Mac",
            "text": f"Checking more than {rounded(APPS, ',')[:-1]} apps took a lot of work. For each one we mapped the folders it works in, checked every one of them and decided what counts as junk. The database is open: read it, check it, suggest new rules.",
            "nums": [(f"{RULES:,}", "cleaning rules"), (f"{APPS:,}", "apps"), (DB_VERSION, "current database")],
            "points": ["MacWashing downloads a fresh database on its own, between app updates", "We keep an eye on new versions and new apps"],
            "wall": f"See all {APPS:,} apps",
        },
        "safety": {
            "kicker": "Safe by design",
            "title": "Built never to delete the wrong thing",
            "text": "MacWashing removes only what it can explain: every file is matched to a known app or a known kind of junk.",
            "items": [
                ("A curated rules database", "We build the database by watching how apps really behave."),
                ("Only known-safe places", "We don’t touch what may matter to you. Only what we’re sure about."),
                ("You see what goes", "Open any find and look it over before it’s removed."),
                ("The Trash if you want it", "Turn on removal to the Trash and leave your worries behind."),
                ("Running apps are respected", "Waits until you finish your work."),
                ("It all stays on your Mac", "Scanning works without the internet, and your data stays with you."),
            ],
        },
        "faq": {
            "kicker": "FAQ",
            "title": "Questions and answers",
            "items": [
                ("Is MacWashing really free?", "Yes. Every section works without limits, and there is no account. The code is open under GPL-3.0: anyone can read it, build it and suggest changes on GitHub."),
                ("Is it safe to clean with MacWashing?", "MacWashing removes only files it can match to a known app or a known kind of junk in its rules database, and only in places apps leave files. Standard system folders and Apple’s files are never touched. You can review and uncheck every item."),
                ("Why does it ask for Full Disk Access?", "macOS hides caches, logs and the permissions database from apps without Full Disk Access. MacWashing needs it to see them. Everything is scanned on your Mac. No file names or lists are sent anywhere."),
                ("Can I get deleted files back?", "By default MacWashing deletes right away, so the space is freed at once. If you want to be able to change your mind, choose To Trash in Settings ▸ Removal: then anything removed can be put back until you empty the Trash."),
                ("Which Macs are supported?", "Any Mac running macOS 14 Sonoma or later, with Apple silicon or Intel."),
                ("How do I uninstall an app on a Mac completely?", "Moving an app to the Trash removes only the app itself. Its settings, caches and background items stay in your Library folder, take up space and sometimes keep launching. In MacWashing, open the Uninstaller and check the app: everything it left is found through the rules database and removed together with it."),
                ("What is System Data on a Mac, and can MacWashing reduce it?", "System Data in Storage settings is everything macOS doesn’t sort into its other categories: caches, logs, Xcode data, Time Machine local snapshots and more. MacWashing removes the caches, logs and Xcode junk. Snapshots and macOS’s own files are left alone, so the number goes down, but not to zero."),
                ("Why is my Mac running slow, and can cleaning speed it up?", "Most often a Mac slows down when its startup disk is nearly full: macOS has no room left for swap files and caches. Clearing caches, logs, Xcode junk and forgotten installers gives the space back. If there is plenty of free space and the Mac is still slow, the cause is more likely the processor or memory load — MacWashing doesn’t fix that."),
                ("How do updates work?", "The app checks GitHub once a day: new versions come from this repository’s releases, signed and notarized, and a newer rules database from its updates folder. Both are signed, and the app checks the signatures before using anything."),
            ],
        },
        "final": ("Ready for a cleaner Mac?", "Download MacWashing — it’s free."),
        "apps": {
            "title": "Apps MacWashing knows — MacWashing",
            "description": f"All {APPS:,} apps in the MacWashing rules database: where each one keeps its files, checked on real installs.",
            "kicker": "The rules database",
            "h1": f"{APPS:,} apps MacWashing knows",
            "text": f"Every app here was installed on a clean Mac in a virtual machine, used, and mapped: where it keeps its caches, settings and background items, and what of it is your own data. {RULES:,} rules in all; the bigger the tile, the more places the app leaves files in.",
            "search": "Find an app",
            "rules": "{n} places",
            "none": "Nothing found. Missing an app? Suggest it on GitHub.",
            "back": "Back to MacWashing",
            "suggest": "Suggest an app",
        },
        "footer": ["Free and open source under GPL-3.0", "Source code", "Changelog", "Apps in the database", "Report a problem"],
    },
    "ru": {
        "lang": "ru",
        "title": "MacWashing — аккуратная очистка Mac и удаление программ, бесплатно и с открытым кодом",
        "description": "MacWashing чистит кэш и мусор, полностью удаляет программы, находит большие файлы и показывает, что занимает место на Mac. Бесплатно и с открытым кодом.",
        "nav": ["Возможности", "База правил", "Безопасность", "Вопросы"],
        "other_lang": ("English", "../"),
        "titleA": "Генеральная уборка для Mac",
        "titleB": "Бесплатно и с открытым кодом",
        "lead": "MacWashing может сохранить здоровье вашего Mac и вернуть ему былую молодость: почистит кэш и мусор, поможет найти большие файлы и освободить место на диске. Забота о вашем Mac — для этого MacWashing здесь.",
        "download": "Скачать для Mac",
        "source": "Код на GitHub",
        "meta": f"Версия <b>{VERSION}</b> · macOS 14 Sonoma и новее · GPL-3.0 · без аккаунта и ограничений",
        "shot_alt": "MacWashing, раздел «Сборка мусора»: найдены кэши Spotify, Telegram, Chrome и других программ, к очистке 72,84 ГБ",
        "stats": [(rounded(RULES, " "), "правил очистки"), (rounded(APPS, " "), "программ в базе правил"), ("5", "инструментов в одном окне"), ("12", "языков интерфейса")],
        "junk": {
            "kicker": "Сборка мусора",
            "title": "Очистка кэша, журналов и остатков программ",
            "text": "Находит всё, что можно удалить без вреда для системы: пользовательские и системные кэши, журналы программ, остатки давно удалённых приложений, забытые установщики и гигабайты мусора Xcode.",
            "points": [
                "DerivedData, старые файлы iOS DeviceSupport и симуляторы, которыми Xcode больше не пользуется",
                "Кэши браузеров и программ: Chrome, Edge, Brave, Opera, Slack, Discord, Notion, Figma, VS Code, Cursor, ChatGPT, Claude, Obsidian, Dropbox и других",
                "Сломанные файлы настроек и элементы входа удалённых программ",
                "Любую категорию можно раскрыть и снять галочку с того, что нужно",
            ],
            "bento": [
                ("Пользовательский кэш", "Кэши программ разрастаются до десятков гигабайт."),
                ("Мусор Xcode", "DerivedData Xcode, данные отладки старых iOS и кэши симуляторов."),
                ("Мусор редакторов", "Кэш Final Cut Pro, Premiere Pro, Lightroom и других."),
                ("Установщики", "Образы дисков и пакеты, забытые в Загрузках."),
                ("Остатки программ", "Настройки и кэши программ, которых на Mac уже нет."),
                ("Журналы", "Программ и системы: для работы они не нужны."),
                ("Остатки старых проектов", "node_modules, Pods, .venv и другие зависимости в проектах, которые вы не открывали больше 90 дней."),
            ],
        },
        "editors": {
            "kicker": "Для фотографов и видеографов",
            "title": "Верните место после монтажа и съёмки",
            "text": "Кэш Final Cut Pro и Premiere Pro, превью Lightroom и кэш DaVinci Resolve — десятки гигабайт на рабочем проекте. Фото, видео и проекты остаются на месте.",
            "apps": "Final Cut Pro · Premiere Pro · Lightroom Classic · DaVinci Resolve · iMovie",
        },
        "uninstaller": {
            "kicker": "Деинсталлятор",
            "title": "Удаление программ с Mac — полностью",
            "text": "Если просто перетащить программу в Корзину, удалится она не полностью: настройки, кэши и фоновые компоненты останутся на диске. Деинсталлятор находит их и удаляет всё вместе.",
            "points": [
                "Сортировка по размеру, имени и последнему запуску, а «Выбрать неиспользуемые» отметит то, что вы давно не открывали",
                "Несколько программ за раз — или только отдельные папки внутри одной",
                "Удаляет и программы, установленные через Homebrew, и инструменты командной строки",
                "Компонент, общий для нескольких программ, удаляется только вместе со всеми ними",
            ],
            "alt": "Деинсталлятор: список программ по размеру с датой последнего открытия, выбран Google Chrome с размером программы и кэшей",
        },
        "large": {
            "kicker": "Большие файлы",
            "title": "Найдите большие файлы, о которых забыли",
            "text": "Видео, архивы и образы дисков, которые вы когда-то скачали и больше не открывали. MacWashing поможет найти крупные и давно забытые файлы на выбранных дисках, а затем вы определите их судьбу.",
            "points": ["Поиск по всему диску или только в выбранных папках", "Найдёт даже то, что спряталось", "Вы сами решаете, что делать с находками"],
            "alt": "Большие файлы: группы по типу, размеру и дате открытия, вверху списка видео, образ Xcode и образ Linux",
        },
        "disk": {
            "kicker": "Хранилище",
            "title": "Посмотрите, что занимает место на Mac",
            "text": "Браузер в духе Finder, который показывает настоящий размер каждой папки. Пройдитесь по домашней папке, iCloud Drive, Корзине и всем дискам и уберите то, что больше не нужно.",
            "points": ["Поможет найти, что реально занимает место на диске", "А затем освободить место в один клик", "Ошиблись? Просто верните файл из Корзины"],
            "alt": "Хранилище: домашняя папка с размером каждой папки, больше всего места занимают Library и Applications",
        },
        "privacy": {
            "kicker": "Приватность",
            "title": "Кому доступны камера, экран и файлы",
            "text": "Показывает, каким программам вы разрешили доступ к камере, микрофону, записи экрана, файлам, автоматизации и остальным разрешениям macOS, — и забирает доступ у тех, кому он не нужен.",
            "chips": ["Камера", "Микрофон", "Запись экрана", "Полный доступ к диску", "Автоматизация", "Универсальный доступ", "Мониторинг ввода", "Файлы и папки", "Контакты", "Календари", "Фото"],
            "alt": "Приватность: категории разрешений с числом программ, выбрана «Камера» — пять программ и кнопка «Запретить» у каждой",
        },
        "more": {
            "kicker": "И ещё кое-что",
            "title": "Вы спросите — MacWashing уже умеет",
            "items": [
                ("А можно при удалении мессенджера стереть историю сообщений и аккаунты?", "Да. **Переписку и аккаунты** деинсталлятор показывает отдельными пунктами: отметьте нужные, и они удалятся вместе с программой. Не отмеченные останутся на случай, если вы поставите мессенджер снова."),
                ("Почему бы просто не перетащить программу в Корзину?", "Так уйдёт только сама программа. MacWashing **чистит глубже**: вместе с ней удаляются её кэши, настройки, журналы и фоновые компоненты, даже из общих папок Mac."),
                ("А если среди мусора есть что-то нужное?", "Всё **по вашим правилам**. Любую находку можно проверить и снять с неё галочку, удалённое — отправлять в Корзину, подтверждение — оставить, а рабочие папки добавить в исключения: туда не заглянет ни одно сканирование."),
                ("А чистить каждый раз вручную? Есть автоочистка?", "**Автоочистка** есть, её включают в Настройках. Когда она включена, раз в день, неделю или месяц MacWashing сам убирает тот же мусор в фоне и присылает уведомление. Открытые программы пропускаются."),
            ],
        },
        "db": {
            "kicker": "База правил",
            "title": "Каждое правило проверено на настоящем Mac",
            "text": f"Нам пришлось приложить немало сил, чтобы проверить более {rounded(APPS, chr(0x202f))[:-1]} приложений. Для каждого мы составили карту рабочих папок, проверили каждую и определили, что может считаться мусором. База открыта: её можно прочитать, проверить и предложить новые правила.",
            "nums": [(f"{RULES:,}".replace(",", " "), "правил очистки"), (f"{APPS:,}".replace(",", " "), "программ"), (DB_VERSION, "текущая версия базы")],
            "points": ["Свежую базу MacWashing скачивает сам, между обновлениями программы", "Следим за выходом новых версий и новых программ"],
            "wall": f"Все {APPS:,} программ".replace(",", " "),
        },
        "safety": {
            "kicker": "Безопасность в основе",
            "title": "Сделан так, чтобы не удалить лишнего",
            "text": "MacWashing удаляет только то, что может объяснить: каждый файл сопоставлен с известной программой или известным видом мусора.",
            "items": [
                ("Собственная база правил", "Базу мы собираем посредством живого анализа поведения программ."),
                ("Только проверенные места", "Мы не трогаем то, что может быть вам дорого. Только то, в чём твёрдо уверены."),
                ("Видно, что удаляется", "Любую находку можно раскрыть и осмотреть перед удалением."),
                ("Корзина — если она вам нужна", "Включите режим удаления в Корзину, чтобы избавиться от лишних тревог."),
                ("Бережно к открытым программам", "Подождёт, пока вы закончите работу."),
                ("Всё остаётся на вашем Mac", "Сканирование идёт без интернета, ваши данные остаются у вас."),
            ],
        },
        "faq": {
            "kicker": "Вопросы",
            "title": "Вопросы и ответы",
            "items": [
                ("MacWashing правда бесплатный?", "Да. Все разделы работают без ограничений, аккаунт не нужен. Код открыт под лицензией GPL-3.0: его можно прочитать, собрать самому и предложить изменения на GitHub."),
                ("Чистить с MacWashing безопасно?", "MacWashing удаляет только те файлы, которые может сопоставить с известной программой или известным видом мусора из своей базы правил, и только там, где программы оставляют файлы. Стандартные системные папки и файлы Apple он не трогает. Каждую находку можно проверить и снять с неё галочку."),
                ("Зачем полный доступ к диску?", "Без полного доступа к диску macOS скрывает от программ кэши, журналы и базу разрешений. Этот доступ нужен MacWashing, чтобы их увидеть. Всё сканируется на вашем Mac, имена и списки файлов никуда не отправляются."),
                ("Можно ли вернуть удалённое?", "По умолчанию MacWashing удаляет сразу, чтобы место освободилось в тот же момент. Если хочется возможности передумать, в Настройках ▸ «Удаление» выберите «В Корзину» — тогда всё удалённое можно вернуть, пока Корзина не очищена."),
                ("На каких Mac работает MacWashing?", "На любом Mac с macOS 14 Sonoma и новее, на Apple silicon и Intel."),
                ("Как полностью удалить программу с Mac?", "Если перетащить программу в Корзину, удалится только она сама. Её настройки, кэши и фоновые компоненты останутся в папке «Библиотеки», будут занимать место, а иногда и запускаться. В MacWashing откройте Деинсталлятор и отметьте программу: всё, что она оставила, найдётся по базе правил и удалится вместе с ней."),
                ("Что такое «Системные данные» и уменьшит ли их MacWashing?", "«Системные данные» в настройках хранилища — всё, что macOS не отнесла к другим категориям: кэши, журналы, данные Xcode, локальные снимки Time Machine и другое. MacWashing удаляет кэши, журналы и мусор Xcode. Снимки и файлы самой macOS он не трогает, поэтому цифра уменьшится, но не до нуля."),
                ("Почему Mac тормозит и ускорит ли его очистка?", "Чаще всего Mac замедляется, когда на загрузочном диске почти не осталось места: macOS негде держать файлы подкачки и кэши. Очистка кэша, журналов, мусора Xcode и забытых установщиков возвращает свободное место. Если места хватает, а Mac всё равно медленный, дело скорее в нагрузке на процессор или память — это MacWashing не лечит."),
                ("Как приходят обновления?", "Раз в день программа заглядывает на GitHub: новые версии приходят из выпусков этого репозитория, подписанные и нотаризованные Apple, а свежая база правил — из папки обновлений. И то и другое подписано, программа проверяет подписи, прежде чем что-то использовать."),
            ],
        },
        "final": ("Готовы к чистому Mac?", "Скачайте MacWashing — это бесплатно."),
        "apps": {
            "title": "Программы, которые знает MacWashing",
            "description": f"Все {APPS} программ базы правил MacWashing: где каждая хранит свои файлы, проверено на настоящих установках.",
            "kicker": "База правил",
            "h1": f"{APPS} программ, которые знает MacWashing",
            "text": f"Каждую программу здесь установили на чистый Mac в виртуальной машине, поработали в ней и составили карту: где она держит кэши, настройки и фоновые компоненты и что из этого — ваши собственные данные. Всего {RULES:,} правил; чем больше плитка, тем в большем числе мест программа оставляет файлы.".replace(",", " "),
            "search": "Найти программу",
            "rules": "мест: {n}",
            "none": "Ничего не нашлось. Нет нужной программы? Предложите её на GitHub.",
            "back": "На главную MacWashing",
            "suggest": "Предложить программу",
        },
        "footer": ["Бесплатно и с открытым кодом, GPL-3.0", "Исходный код", "Что нового", "Программы в базе", "Сообщить о проблеме"],
    },
}


def e(text):
    return html.escape(text, quote=True)


def bold(text):
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", e(text))


def shot(prefix, lang, name, alt, eager=False):
    lang = "en"   # the screenshots are of the English app on both pages
    loading = 'fetchpriority="high"' if eager else 'loading="lazy"'
    return (f'<picture><source type="image/webp" srcset="{prefix}img/{lang}/{name}-1200.webp">'
            f'<img src="{prefix}img/{lang}/{name}-800.jpg" width="1200" height="785" alt="{e(alt)}" {loading} decoding="async"></picture>')


def side(t, key, prefix, lang, name, tone, flip=False, extra=""):
    s = t[key]
    points = "".join(f"<li>{e(p)}</li>" for p in s.get("points", []))
    chips = "".join(f'<span class="chip">{e(c)}</span>' for c in s.get("chips", []))
    return f"""
  <section class="tone-{tone}" id="{key}">
    <div class="wrap side{' flip' if flip else ''}">
      <div class="copy">
        <div class="kicker">{e(s['kicker'])}</div>
        <h2>{e(s['title'])}</h2>
        <p class="text">{e(s['text'])}</p>
        {f'<ul class="points">{points}</ul>' if points else ''}
        {f'<div class="chips">{chips}</div>' if chips else ''}
        {extra}
      </div>
      <div class="shot">{shot(prefix, lang, name, s['alt'])}</div>
    </div>
  </section>"""


def page(lang):
    t = T[lang]
    prefix = "../" if lang == "ru" else ""
    other_name, other_href = t["other_lang"]
    j = t["junk"]
    bento = "".join(
        f'<div class="cell{" wide" if i == 0 else ""}"><h3>{e(a)}</h3><p>{e(b)}</p></div>' for i, (a, b) in enumerate(j["bento"])
    )
    points = "".join(f"<li>{e(p)}</li>" for p in j["points"])
    chat = "".join(f'<div class="q">{e(q)}</div><div class="a">{bold(a)}</div>' for q, a in t["more"]["items"])
    d = t["db"]
    nums = "".join(f'<div class="stat"><b>{e(n)}</b><span>{e(l)}</span></div>' for n, l in d["nums"])
    known = sorted((a for a in ALL_APPS if a[3]), key=lambda a: -a[2])[:21]
    wall = "".join(f'<li title="{e(n)}">{tile_icon(prefix, n, b, i, 56)}</li>' for n, b, _, i in known)
    cards = "".join(f'<div class="card"><h3>{e(a)}</h3><p>{e(b)}</p></div>' for a, b in t["safety"]["items"])
    faq = "".join(f"<details><summary>{e(q)}</summary><p>{e(a)}</p></details>" for q, a in t["faq"]["items"])
    stats = "".join(f'<div class="stat"><b>{e(n)}</b><span>{e(l)}</span></div>' for n, l in t["stats"])
    nav = t["nav"]
    f = t["footer"]
    final_title, final_text = t["final"]
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(t['title'])}</title>
<meta name="description" content="{e(t['description'])}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0b0c10">
<meta property="og:title" content="{e(t['title'])}">
<meta property="og:description" content="{e(t['description'])}">
<meta property="og:type" content="website">
<link rel="icon" href="{prefix}img/favicon.svg" type="image/svg+xml">
<link rel="icon" href="{prefix}img/fav-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="{prefix}img/icon-256.png">
<link rel="alternate" hreflang="en" href="{'../' if lang == 'ru' else './'}">
<link rel="alternate" hreflang="ru" href="{'./' if lang == 'ru' else 'ru/'}">
<link rel="stylesheet" href="{prefix}style.css">
</head>
<body>
<header class="top">
  <div class="wrap">
    <a class="brand" href="./"><img src="{prefix}img/icon-256.png" alt="" width="28" height="28">MacWashing</a>
    <nav>
      <a class="hide-sm" href="#junk">{e(nav[0])}</a>
      <a class="hide-sm" href="#rules">{e(nav[1])}</a>
      <a class="hide-sm" href="#safety">{e(nav[2])}</a>
      <a class="hide-sm" href="#faq">{e(nav[3])}</a>
      <a href="{GITHUB}">GitHub</a>
      <a class="lang" href="{other_href}" hreflang="{'ru' if lang == 'en' else 'en'}">{e(other_name)}</a>
    </nav>
  </div>
</header>
<main>
  <div class="hero">
    <div class="wrap">
      <img class="icon" src="{prefix}img/icon-400.webp" width="148" height="148" alt="">
      <h1><span>{e(t['titleA'])}</span><span class="grad">{e(t['titleB'])}</span></h1>
      <p class="lead">{e(t['lead'])}</p>
      <div class="cta">
        <a class="btn primary" href="{DOWNLOAD}">{DOWNLOAD_ICON}{e(t['download'])}</a>
        <a class="btn" href="{GITHUB}">{GITHUB_ICON}{e(t['source'])}</a>
      </div>
      <p class="meta">{t['meta']}</p>
      <div class="window">{shot(prefix, lang, 'junk-caches', t['shot_alt'], eager=True)}</div>
      <div class="stats">{stats}</div>
    </div>
  </div>

  <section class="tone-junk" id="junk">
    <div class="wrap">
      <div class="center">
        <div class="kicker">{e(j['kicker'])}</div>
        <h2>{e(j['title'])}</h2>
        <p class="text">{e(j['text'])}</p>
      </div>
      <div class="bento">{bento}</div>
      <ul class="points" style="max-width:760px;margin:28px auto 0">{points}</ul>
      <div class="strip">
        <div class="kicker">{e(t['editors']['kicker'])}</div>
        <h2>{e(t['editors']['title'])}</h2>
        <p class="text">{e(t['editors']['text'])}</p>
        <p class="names">{e(t['editors']['apps'])}</p>
      </div>
    </div>
  </section>
{side(t, 'uninstaller', prefix, lang, 'uninstaller-results', 'uninstaller', flip=True)}
{side(t, 'large', prefix, lang, 'large-results', 'large')}
{side(t, 'disk', prefix, lang, 'disk', 'disk', flip=True)}
{side(t, 'privacy', prefix, lang, 'privacy', 'privacy')}

  <section class="tone-uninstaller" id="more">
    <div class="wrap">
      <div class="center">
        <div class="kicker">{e(t['more']['kicker'])}</div>
        <h2>{e(t['more']['title'])}</h2>
      </div>
      <div class="chat">{chat}</div>
    </div>
  </section>

  <section class="tone-junk" id="rules">
    <div class="wrap">
      <div class="center">
        <div class="kicker">{e(d['kicker'])}</div>
        <h2>{e(d['title'])}</h2>
        <p class="text">{e(d['text'])}</p>
      </div>
      <div class="db">
        <div>
          <div class="nums">{nums}</div>
          <ul class="points">{''.join(f'<li>{e(p)}</li>' for p in d['points'])}</ul>
        </div>
        <a class="wall" href="{prefix}apps/">
          <ul>{wall}</ul>
          <span>{e(d['wall'])} →</span>
        </a>
      </div>
    </div>
  </section>

  <section class="tone-disk" id="safety">
    <div class="wrap">
      <div class="center">
        <div class="kicker">{e(t['safety']['kicker'])}</div>
        <h2>{e(t['safety']['title'])}</h2>
        <p class="text">{e(t['safety']['text'])}</p>
      </div>
      <div class="cards">{cards}</div>
    </div>
  </section>

  <section class="tone-junk" id="faq">
    <div class="wrap">
      <div class="center">
        <div class="kicker">{e(t['faq']['kicker'])}</div>
        <h2>{e(t['faq']['title'])}</h2>
      </div>
      <div class="faq">{faq}</div>
      <div class="final">
        <h2>{e(final_title)}</h2>
        <p class="text">{e(final_text)}</p>
        <div class="cta">
          <a class="btn primary" href="{DOWNLOAD}">{DOWNLOAD_ICON}{e(t['download'])}</a>
          <a class="btn" href="{GITHUB}">{GITHUB_ICON}{e(t['source'])}</a>
        </div>
        <p class="meta">{t['meta']}</p>
      </div>
    </div>
  </section>
</main>
<footer>
  <div class="wrap">
    <span>MacWashing · {e(f[0])}</span>
    <span>
      <a href="{GITHUB}">{e(f[1])}</a> ·
      <a href="{GITHUB}/blob/main/CHANGELOG.md">{e(f[2])}</a> ·
      <a href="{prefix}apps/">{e(f[3])}</a> ·
      <a href="{GITHUB}/issues">{e(f[4])}</a>
    </span>
  </div>
</footer>
</body>
</html>
"""


def apps_page(lang):
    t = T[lang]
    a = t["apps"]
    up = "../../" if lang == "ru" else "../"
    other_name, _ = t["other_lang"]
    other_href = "../../apps/" if lang == "ru" else "../ru/apps/"
    counts = sorted(r for _, _, r, _ in ALL_APPS)
    big = counts[int(len(counts) * 0.93)]
    mid = counts[int(len(counts) * 0.75)]
    tiles = []
    for name, bundle_id, rules, icon in ALL_APPS:
        size = "big" if rules >= big else "mid" if rules >= mid else "small"
        px = {"big": 96, "mid": 72, "small": 56}[size]
        tiles.append(
            f'<li class="{size}" data-n="{e(name.casefold())}" title="{e(name)} · {e(a["rules"].format(n=rules))}">'
            f'{tile_icon(up, name, bundle_id, icon, px)}<span class="name">{e(name)}</span></li>'
        )
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(a['title'])}</title>
<meta name="description" content="{e(a['description'])}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0b0c10">
<link rel="icon" href="{up}img/favicon.svg" type="image/svg+xml">
<link rel="icon" href="{up}img/fav-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="{up}img/icon-256.png">
<link rel="stylesheet" href="{up}style.css">
</head>
<body>
<header class="top">
  <div class="wrap">
    <a class="brand" href="../"><img src="{up}img/icon-256.png" alt="" width="28" height="28">MacWashing</a>
    <nav>
      <a href="{GITHUB}">GitHub</a>
      <a class="lang" href="{other_href}" hreflang="{'ru' if lang == 'en' else 'en'}">{e(other_name)}</a>
    </nav>
  </div>
</header>
<main class="tone-junk apps-page">
  <div class="wrap">
    <div class="center">
      <div class="kicker">{e(a['kicker'])}</div>
      <h1>{e(a['h1'])}</h1>
      <p class="text">{e(a['text'])}</p>
      <input class="find" type="search" placeholder="{e(a['search'])}" aria-label="{e(a['search'])}" autocomplete="off">
    </div>
    <ul class="apps">{''.join(tiles)}</ul>
    <p class="none" hidden>{e(a['none'])} <a href="{GITHUB}/issues">{e(a['suggest'])} →</a></p>
    <p class="center back"><a href="../">← {e(a['back'])}</a> · <a href="{GITHUB}/issues">{e(a['suggest'])}</a></p>
  </div>
</main>
<script>
const find = document.querySelector(".find"), tiles = [...document.querySelectorAll(".apps li")], none = document.querySelector(".none");
find.addEventListener("input", () => {{
  const q = find.value.trim().toLowerCase();
  let shown = 0;
  for (const li of tiles) {{ const ok = !q || li.dataset.n.includes(q); li.hidden = !ok; shown += ok; }}
  none.hidden = shown > 0;
}});
</script>
</body>
</html>
"""


if __name__ == "__main__":
    (SITE / "index.html").write_text(page("en"))
    (SITE / "ru").mkdir(exist_ok=True)
    (SITE / "ru" / "index.html").write_text(page("ru"))
    for lang, folder in (("en", SITE / "apps"), ("ru", SITE / "ru" / "apps")):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "index.html").write_text(apps_page(lang))
    print(f"site/index.html, site/ru/index.html, apps pages ({sum(1 for a in ALL_APPS if a[3])} icons): version {VERSION}, rules {RULES}, apps {APPS}, database {DB_VERSION}")
