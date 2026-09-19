# Деплой Bell на Robinhood Chain mainnet (4663)

Складено 19.09.2026. Рішення ради того ж дня: деплой лише на мейннет 4663, тестнет 46630 не підходить, бо там немає фідів.

## 1. Що вирішує людина, а не код

1. **Гаманець.** Новий чи наявний. Адреса деплоєра назавжди лишиться в історії чейна поруч із контрактом, тому мій варіант: окремий новий гаманець під хакатон, ключ у keystore, не в змінній середовища.
2. **ETH на газ.** Симуляція `forge script` 19.09: 3 439 543 газу, максимум 0.000426 ETH за базової ціни 0.0619 gwei (`eth_gasPrice` 19.09, блок 67 135 377). Тобто 0.001 ETH з запасом вистачає і на деплой, і на десятки постів. ТРЕБА ПЕРЕВІРИТИ: офіційний шлях завести ETH на 4663 (міст або вивід з Robinhood), з цієї сесії не перевірявся.
3. **Прив'язка стокенів.** Конструктор `Bell(proxy, feedIds, tokens)` пише прив'язку один раз і назавжди. Верифікованих адрес ERC-8056-токенів AAPL і SPY на 4663 у нас немає, тому за замовчуванням деплоїмо **без прив'язки**: усі перевірки працюють, лише `tokenizedReference` віддає 0. Прив'язана версія деплоїться окремо, коли адреси підтверджені двома незалежними джерелами.

## 2. Передполітна перевірка

```bash
forge fmt --check
forge test                                                        # 65 тестів на моці
forge test --fork-url robinhood --match-contract "VerifyFixture|BellRobustnessFork" -vv   # 6 на реальному проксі
forge build --sizes                                               # Bell runtime 11 845 B, запас ~12 731 B
```

## 3. Деплой

```bash
# симуляція, нічого не відправляє
forge script script/Deploy.s.sol --rpc-url robinhood

# бойовий деплой (ключ з keystore, не з env)
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --account bell-deployer
```

Адреса проксі зашита в скрипті: `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7`. Скрипт падає, якщо за цією адресою немає коду, тобто помилковий чейн відсікається на симуляції.

## 4. Перевірки після деплою

```bash
BELL=<адреса з логів>
cast call $BELL "POLICY_VERSION()(uint32)"   --rpc-url robinhood   # 2
cast call $BELL "CALENDAR_VERSION()(uint32)" --rpc-url robinhood
cast call $BELL "digestActive(bytes32)(bool)" 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee --rpc-url robinhood
cast call $BELL "rungTarget(uint32,bool,uint8)(uint64)" 20260921 false 0 --rpc-url robinhood
```

`digestActive` має бути `true`: проксі 19.09 віддає для цього digest верифаєр `0xb86d1b8a3bb1c5d7809f5e9eb009311d51d933c6` (`getVerifier`, власний eth_call 19.09).

Верифікація вихідного коду в експлорері: ТРЕБА ПЕРЕВІРИТИ адресу експлорера і чи приймає він `forge verify-contract`. З цієї сесії `explorer.chain.robinhood.com` не відкрився (SSL handshake failure), `robinhood.blockscout.com` дає 404.

## 5. Чого деплой сам по собі не дає

Задеплоєний контракт без постера мовчить: кожен `checkSettle` повертає `REJECT / REFERENCE_UNRESOLVED`, бо жодного звіту всередині вікна драбини ніхто не подав. Наші 38 фікстур тут не рятують: жодна з них не покриває сходинку (тест `test_no_real_fixture_second_covers_a_ladder_rung`), а дедлайн постингу 300 с не дає розв'язати старим звітом навіть теоретично. Тобто після деплою лишається рівно один блокер до живого дня: підписка Data Streams (150 $/міс за тикер, docs.chain.link) і постер, який ганяє звіти на цільові секунди.
