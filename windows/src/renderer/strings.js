// All EN/RU text. Mirrors macos/Sources/Strings.swift, plus Windows-only settings strings.
(function () {
  const PHRASES = {
    en: {
      greeting: ["Hi! I'm Clawd 👋", "Ready to code!", "I'm here if you need me", "Hello, friend!",
                 "Reporting for duty 🫡", "Let's build something cool"],
      greetMorning: ["Good morning! ☀️", "Morning! Coffee first? ☕", "Rise and code!"],
      greetEvening: ["Good evening! 🌆", "Evening coding session? Nice"],
      greetNight: ["Coding at night? 🌙", "Shh… the bugs are sleeping", "Night owl mode 🦉"],
      sessionStart: ["New session! Let's go", "Ooh, work! Here we go", "Fresh start ✨",
                     "What are we building today?", "Claws warmed up 🦀"],
      wake: ["Huh? I wasn't sleeping!", "I'm up, I'm up!", "Five more minutes…", "W-what did I miss?"],
      thinking: ["Thinking…", "Hmm, let me think…", "Loading big brain…", "Cooking up a plan",
                 "Connecting the dots…", "Give me a sec 🤔", "Reading your mind…", "Hmm, interesting…", "On it!"],
      lateNight: ["Coding at 3am? Respect 🌙", "Shouldn't we be asleep? 😴", "Night shift again, huh"],
      planning: ["Making a to-do list 📝", "Planning the plan", "Step 1: think. Step 2: code."],
      done: ["Done! Your turn 🎉", "All finished!", "Ta-da! ✨", "Mission complete", "Nailed it 💪",
             "Check it out!", "Fresh code, still warm 🔥", "Your move, captain", "Another one done ✅"],
      oops: ["Oops… let me fix that", "Whoops. Trying again", "That didn't go as planned 😅",
             "Plot twist!", "Hmm, not like that…", "No worries, I got this"],
      breakReminder: ["We've been coding for an hour — water break? 💧", "An hour in! Stretch a little? 🙆",
                      "Time flies… take a short break?"],
      streak: ["On a roll! 🔥 %d edits", "%d edits and counting!", "Combo x%d! 💥"],
      poke: ["Hey! That tickles", "Boop!", "I'm working here!", "*happy claw clicking*", "Hehe 🦀",
             "Again! Again!", "Ow… just kidding", "You rang?", "Personal space, please!", "Pinch pinch 🦀"],
      sleep: ["Zzz…", "Zzz… 💤"],
      sleepTalk: ["*mumbles about semicolons*", "…five more tests…", "*dreams of green checkmarks*",
                  "zzz… merge conflict… zzz"],
      idleQuip: ["*stretches claws*", "Need anything?", "Just chilling 😎", "I'm right here 👀",
                 "Nice wallpaper, by the way", "Did you drink water today? 💧", "*taps claws impatiently*",
                 "Got any bugs for me?", "La la la ♪", "Waiting for the next adventure"],
      dragStart: ["Wheee!", "Where are we going?", "Hey, put me down!", "I can fly! 🕊"],
      dropped: ["Nice spot!", "Phew", "Cozy here", "New home 🏠"],
      waitingPermission: ["Need your OK!", "May I? Approve it please 🙏", "Knock knock — permission?",
                          "Waiting for your green light 🚦"],
      waitingQuestion: ["I have a question!", "Psst, I asked you something", "Your call! 🤔", "Help me pick?"],
      waitingIdle: ["Waiting for you…", "Hello? I'm waiting 👀", "Your turn!", "Still here when you're ready"],
      waitingGeneric: ["Hey, I need you!", "Look at me! 👋"],
      notConnected: ["Connect me to Claude Code in Settings!", "Open Settings so I can see Claude work 🔌"],
      funWriting: ["Tap tap tap…", "Code goes brrr", "Clean code incoming ✨", "Fixing it, trust me",
                   "Writing poetry (in code)", "Ctrl+S is my cardio", "Adding some magic ✨",
                   "Refactoring like a pro", "Typing at crab speed 🦀"],
      funReading: ["Studying the scrolls…", "Let me take a look 👀", "Hmm, interesting code",
                   "Reading the manual (rare!)", "Speed reading…", "Who wrote this? Oh wait…"],
      funSearching: ["Where did I put that…", "Detective mode 🔍", "Searching high and low",
                     "It's here somewhere…", "Sniffing out the code 🐾"],
      funRunning: ["Pressing buttons…", "Claws crossed 🤞", "Please compile…", "Here goes nothing!",
                   "Executing… 🚀", "Hold my coffee ☕"],
      funWeb: ["Asking the internet", "Surfing the web 🏄", "Googling like a pro", "Checking the docs 📚"],
      funAgent: ["Summoning a helper crab 🦀", "Calling backup!", "Assembling the crab squad 🦀🦀"],
      tests: ["Running tests… 🤞", "Test time! Claws crossed", "Please be green, please be green 🟢"],
      gitCommit: ["Committing… 📦", "Saving our progress 💾", "Into the history books!"],
      gitPush: ["Pushing to the cloud ☁️", "Shipping it! 🚢", "Off it goes 🚀"],
      installing: ["Downloading half the internet…", "Installing stuff 📦", "node_modules intensifies"],
      building: ["Building… 🏗", "Compiling, hold tight", "Brick by brick 🧱"],
      deleting: ["Careful… deleting stuff 😬", "Spring cleaning 🧹"],
    },
    ru: {
      greeting: ["Привет! Я Клод 👋", "Готов кодить!", "Я тут, если что", "Привет, друг!",
                 "Прибыл на службу 🫡", "Давай сделаем что-нибудь крутое"],
      greetMorning: ["Доброе утро! ☀️", "Утро! Сначала кофе? ☕", "Проснись и кодь!"],
      greetEvening: ["Добрый вечер! 🌆", "Вечерний кодинг? Одобряю"],
      greetNight: ["Кодим ночью? 🌙", "Тсс… баги спят", "Режим совы 🦉"],
      sessionStart: ["Новая сессия! Погнали", "О, работа! Поехали", "Чистый лист ✨",
                     "Что строим сегодня?", "Клешни размяты 🦀"],
      wake: ["А? Я не спал!", "Я тут, я тут!", "Ещё пять минуточек…", "Ч-что я пропустил?"],
      thinking: ["Думаю…", "Хмм, дай подумать…", "Включаю мозги…", "Придумываю план",
                 "Соединяю точки…", "Секунду 🤔", "Читаю твои мысли…", "Хмм, интересно…", "Принято!"],
      lateNight: ["Кодим в 3 ночи? Уважаю 🌙", "А не пора ли спать? 😴", "Опять ночная смена, да?"],
      planning: ["Составляю список дел 📝", "Планирую план", "Шаг 1: подумать. Шаг 2: кодить."],
      done: ["Готово! Твой ход 🎉", "Всё сделал!", "Та-дам! ✨", "Миссия выполнена", "Сделано 💪",
             "Зацени!", "Свежий код, ещё тёплый 🔥", "Твой ход, капитан", "Ещё одна готова ✅"],
      oops: ["Упс… сейчас поправлю", "Ой. Не вышло, пробую ещё", "Пошло не по плану 😅",
             "Неожиданный поворот!", "Хмм, не так…", "Спокойно, я разберусь"],
      breakReminder: ["Кодим уже час — может, водички? 💧", "Час прошёл! Потянись немного 🙆",
                      "Время летит… сделаем перерыв?"],
      streak: ["В ударе! 🔥 %d правок", "%d правок и не останавливаюсь!", "Комбо x%d! 💥"],
      poke: ["Эй! Щекотно", "Буп!", "Я тут работаю вообще-то!", "*довольно щёлкает клешнями*", "Хи-хи 🦀",
             "Ещё! Ещё!", "Ай… шучу", "Звали?", "Личное пространство!", "Щип-щип 🦀"],
      sleep: ["Zzz…", "Zzz… 💤"],
      sleepTalk: ["*бормочет про точки с запятой*", "…ещё пять тестов…", "*снятся зелёные галочки*",
                  "хрр… мердж-конфликт… хрр"],
      idleQuip: ["*разминает клешни*", "Что-нибудь нужно?", "Просто отдыхаю 😎", "Я тут 👀",
                 "Классные обои, кстати", "Ты сегодня пил воду? 💧", "*нетерпеливо стучит клешнями*",
                 "Есть баги для меня?", "Ля-ля-ля ♪", "Жду новых приключений"],
      dragStart: ["Уиии!", "Куда мы летим?", "Эй, поставь меня!", "Я лечу! 🕊"],
      dropped: ["Хорошее местечко!", "Фух", "Уютненько", "Новый дом 🏠"],
      waitingPermission: ["Нужно твоё разрешение!", "Можно? Нажми там да 🙏", "Тук-тук — разрешишь?",
                          "Жду зелёный свет 🚦"],
      waitingQuestion: ["У меня вопрос!", "Глянь, я кое-что спросил", "Тебе решать! 🤔", "Поможешь выбрать?"],
      waitingIdle: ["Жду тебя…", "Ты где? Я жду 👀", "Твой ход!", "Я тут, когда будешь готов"],
      waitingGeneric: ["Эй, ты мне нужен!", "Посмотри на меня! 👋"],
      notConnected: ["Подключи меня к Claude Code в настройках!", "Открой настройки, чтобы я видел работу Claude 🔌"],
      funWriting: ["Тык-тык-тык…", "Код пошёл!", "Чистый код на подходе ✨", "Чиню, доверься мне",
                   "Пишу поэзию (на коде)", "Ctrl+S — моё кардио", "Добавляю немного магии ✨",
                   "Рефакторю как профи", "Печатаю с крабьей скоростью 🦀"],
      funReading: ["Изучаю свитки…", "Сейчас гляну 👀", "Хмм, интересный код", "Читаю документацию (редкость!)",
                   "Скорочтение…", "Кто это написал? А, точно…"],
      funSearching: ["Куда же я это дел…", "Режим детектива 🔍", "Ищу везде", "Где-то тут было…",
                     "Вынюхиваю код 🐾"],
      funRunning: ["Жму на кнопки…", "Скрестим клешни 🤞", "Лишь бы скомпилилось", "Ну, поехали!",
                   "Выполняю… 🚀", "Подержи мой кофе ☕"],
      funWeb: ["Спрашиваю интернет", "Сёрфлю 🏄", "Гуглю как профи", "Смотрю документацию 📚"],
      funAgent: ["Зову краба-помощника 🦀", "Вызываю подкрепление!", "Собираю крабью команду 🦀🦀"],
      tests: ["Гоняю тесты… 🤞", "Время тестов! Скрестим клешни", "Только бы зелёные 🟢"],
      gitCommit: ["Коммичу… 📦", "Сохраняем прогресс 💾", "В историю!"],
      gitPush: ["Пушу в облако ☁️", "Отправляем! 🚢", "Полетело 🚀"],
      installing: ["Качаю половину интернета…", "Ставлю пакеты 📦", "node_modules растёт"],
      building: ["Собираю… 🏗", "Компилирую, держись", "Кирпичик за кирпичиком 🧱"],
      deleting: ["Осторожно… удаляю 😬", "Генеральная уборка 🧹"],
    },
  };

  const UI = {
    en: {
      settings: "Settings…", language: "Language", hideWhenSleeping: "Hide when sleeping", sayHi: "Say hi",
      playDemo: "Play demo", resetPosition: "Reset position", hide: "Hide buddy", show: "Show buddy",
      quit: "Quit Clawd Buddy",
      tagline: "A pixel pal that watches Claude write code", appearance: "Appearance", behavior: "Behavior",
      claudeCode: "Claude Code", bubbleStyle: "Bubble", stylePixel: "Pixel", styleClaude: "Claude",
      size: "Size", sizeSmall: "Small", sizeMedium: "Medium", sizeLarge: "Large",
      chattiness: "Chattiness", chattinessHint: "How often to joke instead of describing the work",
      idleChatter: "Idle chatter", idleChatterHint: "Quips and little animations while Claude is idle",
      followMouse: "Follow the cursor", followMouseHint: "Eyes look at your mouse",
      hideWhenSleepingHint: "Fades out when asleep, comes back with work",
      launchAtLogin: "Start with Windows", launchAtLoginHint: "So Claude Code always has someone to talk to",
      hooksOn: "Connected to Claude Code", hooksOff: "Not connected",
      hooksHint: "Adds hooks to ~/.claude/settings.json", connect: "Connect", disconnect: "Disconnect",
      hooksError: "Couldn't read settings.json — is it valid JSON?",
      footer: "Unofficial fan project",
    },
    ru: {
      settings: "Настройки…", language: "Язык", hideWhenSleeping: "Прятаться, когда сплю", sayHi: "Поздороваться",
      playDemo: "Показать анимации", resetPosition: "Вернуть в угол", hide: "Спрятать", show: "Показать",
      quit: "Выйти",
      tagline: "Пиксельный друг, который смотрит, как Claude пишет код", appearance: "Внешний вид",
      behavior: "Поведение", claudeCode: "Claude Code", bubbleStyle: "Облачко", stylePixel: "Pixel",
      styleClaude: "Claude", size: "Размер", sizeSmall: "Мелкий", sizeMedium: "Средний", sizeLarge: "Большой",
      chattiness: "Болтливость", chattinessHint: "Как часто шутить вместо описания действий",
      idleChatter: "Болтать без дела", idleChatterHint: "Фразы и анимации, пока Claude отдыхает",
      followMouse: "Следить за курсором", followMouseHint: "Глаза смотрят на мышку",
      hideWhenSleepingHint: "Исчезает, когда засыпает, и возвращается с работой",
      launchAtLogin: "Запускать с Windows", launchAtLoginHint: "Чтобы Claude Code всегда было с кем поговорить",
      hooksOn: "Подключён к Claude Code", hooksOff: "Не подключён",
      hooksHint: "Добавляет хуки в ~/.claude/settings.json", connect: "Подключить", disconnect: "Отключить",
      hooksError: "Не удалось прочитать settings.json — там точно корректный JSON?",
      footer: "Неофициальный фан-проект",
    },
  };

  const ACTIONS = {
    en: {
      edit: (d) => `Editing ${d || "code"}`, write: (d) => `Writing ${d || "a file"}`,
      read: (d) => `Reading ${d || "a file"}`, search: (d) => `Searching: ${d}`, bash: (d) => `Running: ${d}`,
      webSearch: (d) => `Googling: ${d}`, webFetch: (d) => `Opening ${d}`, agent: (d) => `Calling a helper: ${d}`,
      plan: () => "Planning tasks", other: (d, t) => `Using ${d || t}`,
    },
    ru: {
      edit: (d) => `Правлю ${d || "код"}`, write: (d) => `Пишу ${d || "файл"}`,
      read: (d) => `Читаю ${d || "файл"}`, search: (d) => `Ищу: ${d}`, bash: (d) => `Запускаю: ${d}`,
      webSearch: (d) => `Гуглю: ${d}`, webFetch: (d) => `Открываю ${d}`, agent: (d) => `Зову помощника: ${d}`,
      plan: () => "Планирую задачи", other: (d, t) => `Использую ${d || t}`,
    },
  };

  const L10n = {
    lang: "en",
    get buddyName() { return this.lang === "ru" ? "Клод" : "Clawd"; },
    pick(key) {
      const list = PHRASES[this.lang][key] || PHRASES.en[key] || [""];
      return list[Math.floor(Math.random() * list.length)];
    },
    streak(n) { return this.pick("streak").replace("%d", n); },
    ui(key) { return UI[this.lang][key] ?? UI.en[key] ?? key; },
    action(tool, detail) {
      const a = ACTIONS[this.lang];
      switch (tool) {
        case "Edit": case "MultiEdit": case "NotebookEdit": return a.edit(detail);
        case "Write": return a.write(detail);
        case "Read": return a.read(detail);
        case "Grep": case "Glob": return a.search(detail);
        case "Bash": case "PowerShell": return a.bash(detail);
        case "WebSearch": return a.webSearch(detail);
        case "WebFetch": return a.webFetch(detail);
        case "Agent": case "Task": return a.agent(detail);
        case "TodoWrite": case "TaskCreate": case "TaskUpdate": return a.plan();
        default: return a.other(detail, tool);
      }
    },
  };

  // Shared between renderer pages (script tag) and the main process (require).
  if (typeof module !== "undefined") module.exports = { L10n };
  else window.L10n = L10n;
})();
