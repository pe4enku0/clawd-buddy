import Foundation

enum Lang: String, CaseIterable { case en, ru }

enum Phrase {
    case greeting, greetMorning, greetEvening, greetNight, sessionStart, wake
    case thinking, lateNight, planning, done, oops, breakReminder, streak
    case poke, sleep, sleepTalk, idleQuip, dragStart, dropped
    case waitingPermission, waitingQuestion, waitingIdle, waitingGeneric
    case funWriting, funReading, funSearching, funRunning, funWeb, funAgent
    case tests, gitCommit, gitPush, installing, building, deleting
}

enum UIText {
    // menu
    case settings, language, hideWhenSleeping, sayHi, playDemo, resetPosition, hide, show, quit
    // settings window
    case tagline, appearance, behavior, claudeCode
    case bubbleStyle, stylePixel, styleClaude, size, sizeSmall, sizeMedium, sizeLarge
    case chattiness, chattinessHint, idleChatter, idleChatterHint, followMouse, followMouseHint, hideWhenSleepingHint
    case hooks, hooksOn, hooksOff, hooksHint, footer
}

enum L10n {
    static var lang: Lang = .en
    private static var ru: Bool { lang == .ru }

    static var buddyName: String { ru ? "Клод" : "Clawd" }

    static func pick(_ p: Phrase) -> String { list(p).randomElement() ?? "" }

    static func streak(_ n: Int) -> String { String(format: pick(.streak), n) }

    static func action(tool: String, detail: String) -> String {
        let d = detail
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit":
            return ru ? "Правлю \(d.isEmpty ? "код" : d)" : "Editing \(d.isEmpty ? "code" : d)"
        case "Write":
            return ru ? "Пишу \(d.isEmpty ? "файл" : d)" : "Writing \(d.isEmpty ? "a file" : d)"
        case "Read":
            return ru ? "Читаю \(d.isEmpty ? "файл" : d)" : "Reading \(d.isEmpty ? "a file" : d)"
        case "Grep", "Glob":
            return ru ? "Ищу: \(d)" : "Searching: \(d)"
        case "Bash":
            return ru ? "Запускаю: \(d)" : "Running: \(d)"
        case "WebSearch":
            return ru ? "Гуглю: \(d)" : "Googling: \(d)"
        case "WebFetch":
            return ru ? "Открываю \(d)" : "Opening \(d)"
        case "Agent", "Task":
            return ru ? "Зову помощника: \(d)" : "Calling a helper: \(d)"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return ru ? "Планирую задачи" : "Planning tasks"
        default:
            return ru ? "Использую \(d.isEmpty ? tool : d)" : "Using \(d.isEmpty ? tool : d)"
        }
    }

    static func ui(_ t: UIText) -> String {
        switch t {
        case .settings: return ru ? "Настройки…" : "Settings…"
        case .language: return ru ? "Язык" : "Language"
        case .hideWhenSleeping: return ru ? "Прятаться, когда сплю" : "Hide when sleeping"
        case .sayHi: return ru ? "Поздороваться" : "Say hi"
        case .playDemo: return ru ? "Показать анимации" : "Play demo"
        case .resetPosition: return ru ? "Вернуть в угол" : "Reset position"
        case .hide: return ru ? "Спрятать" : "Hide buddy"
        case .show: return ru ? "Показать" : "Show buddy"
        case .quit: return ru ? "Выйти" : "Quit Clawd Buddy"
        case .tagline: return ru ? "Пиксельный друг, который смотрит, как Claude пишет код"
                                 : "A pixel pal that watches Claude write code"
        case .appearance: return ru ? "Внешний вид" : "Appearance"
        case .behavior: return ru ? "Поведение" : "Behavior"
        case .claudeCode: return "Claude Code"
        case .bubbleStyle: return ru ? "Облачко" : "Bubble"
        case .stylePixel: return "Pixel"
        case .styleClaude: return "Claude"
        case .size: return ru ? "Размер" : "Size"
        case .sizeSmall: return ru ? "Мелкий" : "Small"
        case .sizeMedium: return ru ? "Средний" : "Medium"
        case .sizeLarge: return ru ? "Большой" : "Large"
        case .chattiness: return ru ? "Болтливость" : "Chattiness"
        case .chattinessHint: return ru ? "Как часто шутить вместо описания действий" : "How often to joke instead of describing the work"
        case .idleChatter: return ru ? "Болтать без дела" : "Idle chatter"
        case .idleChatterHint: return ru ? "Фразы и анимации, пока Claude отдыхает" : "Quips and little animations while Claude is idle"
        case .followMouse: return ru ? "Следить за курсором" : "Follow the cursor"
        case .followMouseHint: return ru ? "Глаза смотрят на мышку" : "Eyes look at your mouse"
        case .hideWhenSleepingHint: return ru ? "Исчезает, когда засыпает, и возвращается с работой" : "Fades out when asleep, comes back with work"
        case .hooks: return ru ? "Хуки" : "Hooks"
        case .hooksOn: return ru ? "Подключён к Claude Code" : "Connected to Claude Code"
        case .hooksOff: return ru ? "Хуки не найдены" : "Hooks not found"
        case .hooksHint: return ru ? "Запусти ./install.sh в папке проекта" : "Run ./install.sh in the project folder"
        case .footer: return ru ? "Неофициальный фан-проект" : "Unofficial fan project"
        }
    }

    private static func list(_ p: Phrase) -> [String] {
        switch p {
        case .greeting:
            return ru ? ["Привет! Я Клод 👋", "Готов кодить!", "Я тут, если что", "Привет, друг!",
                         "Прибыл на службу 🫡", "Давай сделаем что-нибудь крутое"]
                      : ["Hi! I'm Clawd 👋", "Ready to code!", "I'm here if you need me", "Hello, friend!",
                         "Reporting for duty 🫡", "Let's build something cool"]
        case .greetMorning:
            return ru ? ["Доброе утро! ☀️", "Утро! Сначала кофе? ☕", "Проснись и кодь!"]
                      : ["Good morning! ☀️", "Morning! Coffee first? ☕", "Rise and code!"]
        case .greetEvening:
            return ru ? ["Добрый вечер! 🌆", "Вечерний кодинг? Одобряю"]
                      : ["Good evening! 🌆", "Evening coding session? Nice"]
        case .greetNight:
            return ru ? ["Кодим ночью? 🌙", "Тсс… баги спят", "Режим совы 🦉"]
                      : ["Coding at night? 🌙", "Shh… the bugs are sleeping", "Night owl mode 🦉"]
        case .sessionStart:
            return ru ? ["Новая сессия! Погнали", "О, работа! Поехали", "Чистый лист ✨",
                         "Что строим сегодня?", "Клешни размяты 🦀"]
                      : ["New session! Let's go", "Ooh, work! Here we go", "Fresh start ✨",
                         "What are we building today?", "Claws warmed up 🦀"]
        case .wake:
            return ru ? ["А? Я не спал!", "Я тут, я тут!", "Ещё пять минуточек…", "Ч-что я пропустил?"]
                      : ["Huh? I wasn't sleeping!", "I'm up, I'm up!", "Five more minutes…", "W-what did I miss?"]
        case .thinking:
            return ru ? ["Думаю…", "Хмм, дай подумать…", "Включаю мозги…", "Придумываю план",
                         "Соединяю точки…", "Секунду 🤔", "Читаю твои мысли…", "Хмм, интересно…", "Принято!"]
                      : ["Thinking…", "Hmm, let me think…", "Loading big brain…", "Cooking up a plan",
                         "Connecting the dots…", "Give me a sec 🤔", "Reading your mind…", "Hmm, interesting…", "On it!"]
        case .lateNight:
            return ru ? ["Кодим в 3 ночи? Уважаю 🌙", "А не пора ли спать? 😴", "Опять ночная смена, да?"]
                      : ["Coding at 3am? Respect 🌙", "Shouldn't we be asleep? 😴", "Night shift again, huh"]
        case .planning:
            return ru ? ["Составляю список дел 📝", "Планирую план", "Шаг 1: подумать. Шаг 2: кодить."]
                      : ["Making a to-do list 📝", "Planning the plan", "Step 1: think. Step 2: code."]
        case .done:
            return ru ? ["Готово! Твой ход 🎉", "Всё сделал!", "Та-дам! ✨", "Миссия выполнена", "Сделано 💪",
                         "Зацени!", "Свежий код, ещё тёплый 🔥", "Твой ход, капитан", "Ещё одна готова ✅"]
                      : ["Done! Your turn 🎉", "All finished!", "Ta-da! ✨", "Mission complete", "Nailed it 💪",
                         "Check it out!", "Fresh code, still warm 🔥", "Your move, captain", "Another one done ✅"]
        case .oops:
            return ru ? ["Упс… сейчас поправлю", "Ой. Не вышло, пробую ещё", "Пошло не по плану 😅",
                         "Неожиданный поворот!", "Хмм, не так…", "Спокойно, я разберусь"]
                      : ["Oops… let me fix that", "Whoops. Trying again", "That didn't go as planned 😅",
                         "Plot twist!", "Hmm, not like that…", "No worries, I got this"]
        case .breakReminder:
            return ru ? ["Кодим уже час — может, водички? 💧", "Час прошёл! Потянись немного 🙆", "Время летит… сделаем перерыв?"]
                      : ["We've been coding for an hour — water break? 💧", "An hour in! Stretch a little? 🙆", "Time flies… take a short break?"]
        case .streak:
            return ru ? ["В ударе! 🔥 %d правок", "%d правок и не останавливаюсь!", "Комбо x%d! 💥"]
                      : ["On a roll! 🔥 %d edits", "%d edits and counting!", "Combo x%d! 💥"]
        case .poke:
            return ru ? ["Эй! Щекотно", "Буп!", "Я тут работаю вообще-то!", "*довольно щёлкает клешнями*", "Хи-хи 🦀",
                         "Ещё! Ещё!", "Ай… шучу", "Звали?", "Личное пространство!", "Щип-щип 🦀"]
                      : ["Hey! That tickles", "Boop!", "I'm working here!", "*happy claw clicking*", "Hehe 🦀",
                         "Again! Again!", "Ow… just kidding", "You rang?", "Personal space, please!", "Pinch pinch 🦀"]
        case .sleep:
            return ["Zzz…", "Zzz… 💤"]
        case .sleepTalk:
            return ru ? ["*бормочет про точки с запятой*", "…ещё пять тестов…", "*снятся зелёные галочки*", "хрр… мердж-конфликт… хрр"]
                      : ["*mumbles about semicolons*", "…five more tests…", "*dreams of green checkmarks*", "zzz… merge conflict… zzz"]
        case .idleQuip:
            return ru ? ["*разминает клешни*", "Что-нибудь нужно?", "Просто отдыхаю 😎", "Я тут 👀", "Классные обои, кстати",
                         "Ты сегодня пил воду? 💧", "*нетерпеливо стучит клешнями*", "Есть баги для меня?", "Ля-ля-ля ♪", "Жду новых приключений"]
                      : ["*stretches claws*", "Need anything?", "Just chilling 😎", "I'm right here 👀", "Nice wallpaper, by the way",
                         "Did you drink water today? 💧", "*taps claws impatiently*", "Got any bugs for me?", "La la la ♪", "Waiting for the next adventure"]
        case .dragStart:
            return ru ? ["Уиии!", "Куда мы летим?", "Эй, поставь меня!", "Я лечу! 🕊"]
                      : ["Wheee!", "Where are we going?", "Hey, put me down!", "I can fly! 🕊"]
        case .dropped:
            return ru ? ["Хорошее местечко!", "Фух", "Уютненько", "Новый дом 🏠"]
                      : ["Nice spot!", "Phew", "Cozy here", "New home 🏠"]
        case .waitingPermission:
            return ru ? ["Нужно твоё разрешение!", "Можно? Нажми там да 🙏", "Тук-тук — разрешишь?", "Жду зелёный свет 🚦"]
                      : ["Need your OK!", "May I? Approve it please 🙏", "Knock knock — permission?", "Waiting for your green light 🚦"]
        case .waitingQuestion:
            return ru ? ["У меня вопрос!", "Глянь, я кое-что спросил", "Тебе решать! 🤔", "Поможешь выбрать?"]
                      : ["I have a question!", "Psst, I asked you something", "Your call! 🤔", "Help me pick?"]
        case .waitingIdle:
            return ru ? ["Жду тебя…", "Ты где? Я жду 👀", "Твой ход!", "Я тут, когда будешь готов"]
                      : ["Waiting for you…", "Hello? I'm waiting 👀", "Your turn!", "Still here when you're ready"]
        case .waitingGeneric:
            return ru ? ["Эй, ты мне нужен!", "Посмотри на меня! 👋"] : ["Hey, I need you!", "Look at me! 👋"]
        case .funWriting:
            return ru ? ["Тык-тык-тык…", "Код пошёл!", "Чистый код на подходе ✨", "Чиню, доверься мне", "Пишу поэзию (на коде)",
                         "Ctrl+S — моё кардио", "Добавляю немного магии ✨", "Рефакторю как профи", "Печатаю с крабьей скоростью 🦀"]
                      : ["Tap tap tap…", "Code goes brrr", "Clean code incoming ✨", "Fixing it, trust me", "Writing poetry (in code)",
                         "Ctrl+S is my cardio", "Adding some magic ✨", "Refactoring like a pro", "Typing at crab speed 🦀"]
        case .funReading:
            return ru ? ["Изучаю свитки…", "Сейчас гляну 👀", "Хмм, интересный код", "Читаю документацию (редкость!)",
                         "Скорочтение…", "Кто это написал? А, точно…"]
                      : ["Studying the scrolls…", "Let me take a look 👀", "Hmm, interesting code", "Reading the manual (rare!)",
                         "Speed reading…", "Who wrote this? Oh wait…"]
        case .funSearching:
            return ru ? ["Куда же я это дел…", "Режим детектива 🔍", "Ищу везде", "Где-то тут было…", "Вынюхиваю код 🐾"]
                      : ["Where did I put that…", "Detective mode 🔍", "Searching high and low", "It's here somewhere…", "Sniffing out the code 🐾"]
        case .funRunning:
            return ru ? ["Жму на кнопки…", "Скрестим клешни 🤞", "Лишь бы скомпилилось", "Ну, поехали!", "Выполняю… 🚀", "Подержи мой кофе ☕"]
                      : ["Pressing buttons…", "Claws crossed 🤞", "Please compile…", "Here goes nothing!", "Executing… 🚀", "Hold my coffee ☕"]
        case .funWeb:
            return ru ? ["Спрашиваю интернет", "Сёрфлю 🏄", "Гуглю как профи", "Смотрю документацию 📚"]
                      : ["Asking the internet", "Surfing the web 🏄", "Googling like a pro", "Checking the docs 📚"]
        case .funAgent:
            return ru ? ["Зову краба-помощника 🦀", "Вызываю подкрепление!", "Собираю крабью команду 🦀🦀"]
                      : ["Summoning a helper crab 🦀", "Calling backup!", "Assembling the crab squad 🦀🦀"]
        case .tests:
            return ru ? ["Гоняю тесты… 🤞", "Время тестов! Скрестим клешни", "Только бы зелёные 🟢"]
                      : ["Running tests… 🤞", "Test time! Claws crossed", "Please be green, please be green 🟢"]
        case .gitCommit:
            return ru ? ["Коммичу… 📦", "Сохраняем прогресс 💾", "В историю!"]
                      : ["Committing… 📦", "Saving our progress 💾", "Into the history books!"]
        case .gitPush:
            return ru ? ["Пушу в облако ☁️", "Отправляем! 🚢", "Полетело 🚀"]
                      : ["Pushing to the cloud ☁️", "Shipping it! 🚢", "Off it goes 🚀"]
        case .installing:
            return ru ? ["Качаю половину интернета…", "Ставлю пакеты 📦", "node_modules растёт"]
                      : ["Downloading half the internet…", "Installing stuff 📦", "node_modules intensifies"]
        case .building:
            return ru ? ["Собираю… 🏗", "Компилирую, держись", "Кирпичик за кирпичиком 🧱"]
                      : ["Building… 🏗", "Compiling, hold tight", "Brick by brick 🧱"]
        case .deleting:
            return ru ? ["Осторожно… удаляю 😬", "Генеральная уборка 🧹"]
                      : ["Careful… deleting stuff 😬", "Spring cleaning 🧹"]
        }
    }
}
