# Bell v0.1: специфікація (автор нова модель-критик, 17.09.2026 16:53; мої поправки у розділі 8)

Статус: прийнято як робоча спека для Bell.sol і тестів після перевірки календаря (DST 2026: 08.03 і 01.11, ранні закриття 27.11 і 24.12 о 13:00 ET, 03.07 повний вихідний; NYSE Group calendar). Джерела правил: Chainlink v11 schema, Chainlink onchain verification, Arbitrum finality docs.

## 1. Параметри і сесія

- Пороги MVP: N = 300 с, MAX_OBS_AGE = 30 с, MAX_MID_AGE = 60 с, MAX_CLOCK_SKEW = 2 с; незмінні протягом сесії.
- sessionId = hash(feedId, tradingDateET, policyVersion, calendarVersion); O відкриття, C закриття; регулярний інтервал [O, C).
- UTC-межі обчислюються наперед через America/New_York; затверджений календар фіксується до сесії.

| День / режим | ET | UTC |
|---|---|---|
| Звичайний, EST | 09:30-16:00 | 14:30-21:00 |
| Звичайний, EDT | 09:30-16:00 | 13:30-20:00 |
| 27.11.2026; 24.12.2026 | 09:30-13:00 | 14:30-18:00 |
| Вихідний / біржове свято, включно з 03.07.2026 | сесії нема | NO_SESSION |

- DST 2026: початок 08.03, завершення 01.11; тести торгових днів: 06.03 → 14:30 UTC; 09.03 → 13:30; 30.10 → 13:30; 02.11 → 14:30.
- Календар обмежує допустимість; сам по собі не встановлює marketStatus = 2.

## 2. Сесійна референсна ціна за політикою Bell (policy v2, «драбина», 18.09.2026)

> Термін 19.09.2026: усюди «сесійна референсна ціна за політикою Bell» (OPEN-референс, CLOSE-референс). Не «офіційний принт»: офіційний open/close друкує біржа, Bell робить власний відбір із підписаних звітів DON і каже, за яким правилом.

- Позначення: v = validFromTimestamp, o = observationsTimestamp, l = lastSeenTimestampNs, t = block.timestamp прийняття; ціна mid, без lastTradedPrice.
- Модель звіту: підписане вікно [v, o]. Chainlink: «every time interval belonging to exactly one report» (docs.chain.link/data-streams/how-report-timestamps-work). У 38 різних мейннет-фікстурах вікно 1 с (34) або 2 с (4).
- Сходинки: RUNGS = 8, RUNG = 30 с. OPEN: T_i = O + 30·i; CLOSE: T_i = C − 1 − 30·i; i = 0..7. Цілі задає лише календар.
- Доказ для сходинки i: будь-який прийнятий звіт із v ≤ T_i ≤ o, поданий до дедлайну (OPEN: O ≤ t < O + N; CLOSE: C − N ≤ t < C + N). Звіт може бути доказом для кількох сходинок, якщо його вікно ширше за 30 с.
- Придатність кандидата: status = 2, l > 0, o − 60 ≤ l/10⁹ ≤ o + 2; OPEN додатково l ≥ O × 10⁹; CLOSE додатково o < C і l < C × 10⁹.
- Придатний доказ = кандидат сходинки i. Непридатний доказ = сходинка i доведено непридатна (біт i у provenMask).
- Референс = кандидат на найнижчій сходинці i, для якої всі сходинки 0..i−1 доведено непридатні. Нижча сходинка замінює вищу незалежно від порядку транзакцій; вища при наявній нижчій ігнорується.
- Конфлікт (→ UNRESOLVED): два різні твердження DON про одну сходинку: (а) два кандидати з різним (v, o, mid, l); (б) кандидат і доказ непридатності на одній сходинці. Дублікат (той самий зміст, інші байти) не конфлікт. Конфлікт на вищій сходинці не має значення, якщо нижче є чистий кандидат.
- Фіналізація: t ≥ O + N / t ≥ C + N; нема кандидата, розірваний ланцюг доказів або конфлікт → UNRESOLVED; fallback на попередню ціну заборонений. Пізній звіт після дедлайну не змінює ні кандидата, ні конфлікт.
- Гарантія: у постера лишається лише вибір «подати чи ні». Замовчування будь-якої сходинки = UNRESOLVED (liveness), ніколи не інша ціна (safety). Policy v1 («мінімальний o у вікні N») відкликано 18.09: постер міг притримати звіт 13:30:00 і подати 13:32:10, контракт цього не бачив.
- Секунди поза сходинками (наприклад O + 3) не є доказом ні для чого; такий звіт зберігається лише як latest.
- Нормалізація: tokenizedReference = mid × multiplier / 10¹⁸ зі снапшотом uiMultiplier у момент прийняття кандидата; повертає 0, поки фаза не FINAL.
- Policy v3 (кандидат, не реалізовано): середнє mid по всіх 8 сходинках із вимогою 8/8 доказів. Це змінює сам обʼєкт контракту; розглядати лише після MAE-тесту проти офіційного open на платному стрімі.

## 3. Стани та переходи

| Перехід | Умова |
|---|---|
| NO_DATA → OPEN_PENDING | t ≥ O, сесія існує, OPEN deadline ще не минув |
| OPEN_PENDING → OPEN_FINAL | OPEN deadline минув; кандидат на сходинці i; сходинки 0..i−1 доведено непридатні; немає конфлікту |
| OPEN_PENDING → UNRESOLVED(OPEN) | deadline; NO_ELIGIBLE_REPORT, CONFLICTING_REPORTS або UNVERIFIABLE_HISTORY |
| OPEN_FINAL / UNRESOLVED(OPEN) → CLOSE_PENDING | t ≥ C, CLOSE deadline ще не минув |
| CLOSE_PENDING → CLOSE_FINAL | CLOSE deadline минув; кандидат на сходинці i; сходинки 0..i−1 доведено непридатні; немає конфлікту |
| CLOSE_PENDING → UNRESOLVED(CLOSE) | deadline; ті самі причини |

- Стани обчислюються за часом навіть без виклику keeper; виклик після пропущеного deadline не відкриває нове вікно.
- Результати OPEN і CLOSE зберігаються окремо; CLOSE_FINAL не означає успішного OPEN.
- Фіналізований результат фази незмінний у канонічній історії; запізнілий backfill → WINDOW_CLOSED.

## 4. Guard: перевірки та коди

- Пріоритет: REJECT → WAIT → ALLOW; жодна операція не виконується при WAIT/REJECT.
- getVerifier(digest) має повернути дозволений verifier; далі обовʼязковий успішний verify(). Ненульовий маршрут сам по собі не доводить активність digest.

| Перевірка | Результат |
|---|---|
| Невірні schema/feed/signature; невідомий verifier | REJECT: INVALID_REPORT / WRONG_FEED / UNKNOWN_VERIFIER |
| Deactivated digest; інший збій verification | REJECT: DIGEST_INACTIVE / VERIFICATION_FAILED |
| t > expiresAt; validFrom > o; mid ≤ 0; відсутній множник | REJECT: EXPIRED / BAD_TIMESTAMPS / BAD_PRICE / MISSING_SCALE |
| o > t + 2 або l > (o + 2) × 10⁹ | REJECT: CLOCK_SKEW |
| t < validFrom або t < o ≤ t + 2 | WAIT: NOT_YET_VALID |
| LIVE: t − o > 30 с або t × 10⁹ − l > 60 × 10⁹ | WAIT: OBS_STALE / MID_STALE |
| LIVE: status 0; status 1/3/4/5; поза [O, C) | WAIT: STATUS_UNKNOWN / NON_REGULAR / OUTSIDE_SESSION |
| FIXING: кандидат не відповідає розділу 2 | REJECT: INELIGIBLE_REFERENCE_REPORT |
| SETTLE: фаза pending / unresolved | WAIT: REFERENCE_PENDING / REJECT: REFERENCE_UNRESOLVED |
| Усі перевірки відповідного режиму виконані | ALLOW |

- SETTLE використовує збережений FINAL receipt; LIVE-пороги й поточний expiresAt історичного звіту повторно не застосовуються.
- Freshness через lastSeenTimestampNs перевіряється лише для mid; сувора монотонність l не вимагається.

## 5. Receipts і ротація

- Для кожного прийнятого звіту: receiptId, hash підписаного payload, feedId, digest, proxy, routed verifier, validFrom, o, expiresAt, l, mid, status, acceptedAt, block number, session/phase, policy/calendar versions, multiplier/version, eligibility.
- Payload доступний у calldata та архіві; індексатор додає txHash, blockHash, logIndex, canonicality.
- Верифікація й запис receipt атомарні; невдала верифікація не створює accepted receipt.
- Новий digest проходить ті самі перевірки; не створює нової сесії й не обнуляє кандидатів.
- Деактивація digest не переписує вже перевірені receipts; неперевірюваний backfill не вважається доказом відсутності ранішого звіту.

## 6. Фінальність на Orbit

- OPEN_FINAL / CLOSE_FINAL означає завершення вікна Bell, не фінальність rollup.
- Same-chain consumer читає FINAL атомарно; при реоргу receipt і залежна операція відкочуються разом.
- Cross-chain consumer приймає reference лише через перевірений канал із явно заданою політикою фінальності source chain; локальний таймер Bell або довільні N блоків її не замінюють.
- Індексатор відкликає orphaned receipts; повторне включення після deadline → WINDOW_CLOSED.
- Цензура може змінити набір прийнятих звітів; коротке вікно Bell не гарантує включення challenger.

## 7. Bell Replay: 30 кейсів pplmaverick

- Manifest: chainId, обидві повні адреси, діапазон блоків, hashes, ABI/code version, caseId, lock/expiry/settle times, напрям, strike, кількість, collateral, fees, actual payout.
- 27 + 3 = 30 settlement-кейсів; 27 lockPrice == settlePrice це аномалії для перевірки, не автоматично 27 дефектів; два додаткові дефекти зберігаються як заявлена класифікація до відтворення.
- Цільовий момент і функція виплати беруться з історичних правил consumer. Порівняння з іншою політикою Bell позначається COUNTERFACTUAL, не порушенням контракту.
- DS_RECONSTRUCTED: історичні підписані Data Streams reports, правильні feed/date/scale; повна пагінація, правило розділу 2, перевірка автентичності в історичному контексті. Поточні expiresAt/digest не підміняють історичну перевірку.
- Історичний API не доводить своєчасного прийняття Bell; без тодішніх receipts результат завжди реконструкція.
- OHLC_PROXY: денний Open/Close лише для відповідної межі, зі збереженими provider, timezone, adjustment mode; не підміна точного DON-reference чи довільного intraday expiry.
- expectedPayout = historicalPayoff(reference, position, fees, caps, rounding); Δ = actualPayout − expectedPayout; Δ > 0 переплата отримувачу. Усі значення в мінімальних одиницях payout-token.
- Недостатні звіти / невідомі правила / неперевірювана автентичність → NO_DATA / UNKNOWN_RULE / UNVERIFIABLE; Δ = null, не нуль.
- Звіт окремо рахує CONFIRMED_DEFECT, NO_DEFECT, COUNTERFACTUAL, OHLC_PROXY, невизначені; знаменник підтверджених дефектів включає лише повністю перевірені кейси.

## 8. Мої поправки і відкриті рішення (17.09)

8.1 **CONFLICTING_REPORTS → UNRESOLVED це liveness-ризик.** Два звіти з однаковим o і різним mid обидва підписані DON-ом; чи буває таке в реальному потоці, не виміряно (48 звітів 0x2a77 мали часи рівно :00:00, бо бралися за timestamp). Пропозиція: детермінований tie-break (менший l, потім менший hash payload) замість UNRESOLVED, з подією CONFLICT_TIEBREAK, щоб сесія не вмирала через артефакт каденсу DON. Рішення після виміру на живому потоці в перший день підписки.
8.2 **OPEN-вікно N = 300 с без пізнього backfill означає, що постер має бути надійним:** два незалежні постери (локальний cron і хмарний), спроби з 13:30:02 UTC кожні 5 с до успіху. Запізнення понад 5 хв = UNRESOLVED(OPEN) за дизайном; consumer з Guard отримає REJECT: REFERENCE_UNRESOLVED, це і є правильна поведінка.
8.3 **Replay залежить від зберігання історичних звітів у API Chainlink.** Кейси pplmaverick датовані 03.07-25.08 (0x72DA) і 06-12.09 (0x59DF). Якщо ретенція коротша, липневі кейси йдуть у UNVERIFIABLE, а не в знаменник; число для пітчу тоді «N з M повністю перевірених», не 30/30. Перевірка ретенції: див. чат сесії 17.09 і README.
8.4 **Демо для суддів має три шари з підписами:** LIVE (мейннет, реальні звіти), REPLAY (реконструкція), MOCK (Chainlink Local, синтетика для раннього закриття). Змішувати заборонено.
8.5 Хук SessionGuard-lite поза v0.1.
8.6 **(18.09) Policy v2 «драбина» замість «перший прінт».** Друга LLM (GPT, Раунд 5, розділ H) показала вибір ціни замовчуванням у v1; радник додав вкладення замість рівності (2 з 38 фікстур мають o = T + 1, Chainlink документує вікна без пропусків і перекриттів). Реалізовано в src/Bell.sol (POLICY_VERSION = 2), тести test/BellLadder.t.sol (20), мутаційна перевірка docs/MUTATION-2026-09-18.md. Відкрите: семантика REST «звіт за T» (вікно ∋ T чи o == T) перевіряється на платному стрімі запитами T, T+1, T+2 навколо сходинки. Поправка 8.1 (tie-break замість UNRESOLVED) не застосована: конфлікт лишається UNRESOLVED, бо під моделлю «одна секунда = один звіт» два різні звіти на одній сходинці означають порушення моделі, а не артефакт каденсу.
