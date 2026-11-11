# ThermalWatch

Hlídá, jestli tě **přehřátý Mac nezpomaluje při práci**, a když ano, řekne ti
rovnou **co ho hřeje**, ať to můžeš zavřít. Bez `sudo`, bez účtu, bez volání
jakéhokoli modelu — je to obyčejný Swift binárník, takže nespotřebovává žádné
kredity. Jediné síťové volání v celém kódu je volitelný POST na ntfy při alertu
(`src/Alerter.swift`, `sendRemote`).

V liště je to tichá tečka s procentem. Hlasité je to jen tehdy, když systém
opravdu omezuje výkon.

## Co to stojí

**Změřeno, ne odhadnuto:** 0,50 s CPU za 150 s běhu = **0,33 % jednoho jádra**,
0,033 % desetijádrového stroje; 55 MB RSS; `ps` hlásí 0,0 %. Měřeno včetně startu
(úklid logu, agregace, výpočet reference), v ustáleném běhu je to méně.

Z čeho ta spotřeba je:

* **Tepelný tlak** se čte každých 5 s a je zadarmo — jedno `notify_get_state`.
* **Rychlost jádra** se měří jednou za minutu (a po 20 s, když je horko), protože
  jedno měření stojí ~104 ms práce jednoho jádra. To je ta drahá část, proto je
  řídká.
* **Seznam viníků** (`ps`, ~15 ms) se zjišťuje nejvýš jednou za 30 s a jen když
  tlak není `Nominal`.

## Metrika: Darwin notify klíč, ne `ProcessInfo`

```
notifyutil -g com.apple.system.thermalpressurelevel   →  2
```

Hodnoty 0–4 jsou `Nominal`, `Moderate`, `Heavy`, `Trapping`, `Sleeping`; škála je
z hlavičky SDK na tomhle stroji,
`…/MacOSX27.0.sdk/usr/include/libkern/OSThermalNotification.h`, větev
`#if TARGET_OS_OSX`. **Heavy a výš = systém reálně omezuje výkon.** Root není
potřeba (`src/Pressure.swift`).

Past, kvůli které tenhle nástroj existuje: **`ProcessInfo.thermalState` throttling
maskuje.** Ve stejném okamžiku, kdy notify klíč hlásil `2` (Heavy), vracelo veřejné
API `fair` — slévá `Moderate` a `Heavy` do jedné hodnoty. Většina návodů staví
právě na něm.

Slepé uličky, všechny ověřené spuštěním na tomhle M5:

| zdroj | výsledek |
|---|---|
| `pmset -g therm` | `No CPU power status has been recorded` — `CPU_Speed_Limit` je intelovský, na Apple Silicon mrtvý |
| `pmset -g thermlog` | prázdné |
| `sysctl -a \| grep -i thermal` | nic |
| `powermetrics -s smc,thermal` | `must be invoked as the superuser` |
| `ioreg -c AppleSMC` | `AppleARMPMUTempSensor` teplotu v properties nevystavuje |

## Druhá metrika: o kolik jsi pomalejší

Referenční smyčka v dávkách, nejlepší čas proti referenci. Říká *o kolik*, a
odliší teplo od obyčejného zahlcení CPU. **Sama o sobě nikdy nedá červenou** —
zastropuje se na „mírné“, protože je citlivá na souboj o jádra. Červená znamená,
že systém opravdu omezuje výkon.

Tři věci, které tohle měření rozbíjely. Každá stála jeden chybný výsledek:

* **Optimalizátor smyčku odstranil.** S `-O` vracelo měření 0 ns: devět volání
  čisté funkce se stejnými argumenty Swift sloučí do jednoho (CSE). Seed se proto
  bere per-call z časovače. `src/Sampler.swift` → `burstNanos()`.
* **Rozjezd taktu.** Vlákno, které spí a pak chvíli počítá, dostane nízkou
  frekvenci — DVFS se řídí historií thread group. Na zatíženém stroji stačilo
  10 ms warmupu, ale na **nečinném** ne: 12 ms → 691/561/614 µs, 24 ms →
  533/545/544 µs, 48 ms → 410/359/411 µs, 100 ms → 344/343/343 µs. S krátkým
  warmupem hlásil zdravý nečinný stroj „60 %“ — měřicí chyba, ne throttling.
  Proto `warmups = 250` dávek ≈ 100 ms.
* **Reference nesmí být minimum.** Měření je dvouvrcholové (občas ~360 µs, když je
  jádro od jiné práce rozjeté, obvykle ~600 µs); minimum se chytne té výjimky a
  pak i zdravý stroj hlásí 60 %. Reference je proto **desátý percentil časů
  naměřených ve stejných podmínkách** (agent vs. CLI) za 7 dní — „jak rychle to
  tady jede, když je dobře“. `src/Store.swift` → `reference()`.

## Upozornění

* **Plovoucí okno**, vidět i nad aplikací na celou obrazovku — `display notification`
  se při Focusu a ve full-screenu schová do Centra oznámení, tedy přesně tehdy, kdy
  se vibecoduje. Fokus z editoru nekrade, má tlačítko *Ztlumit na hodinu*.
* **Obsahuje viníky:** tři nejžravější procesy, takže je vidět akce, ne jen varování.
* **Push na mobil** přes [ntfy.sh](https://ntfy.sh) — volitelné, dokud je `ntfyTopic`
  prázdné, neodchází ze stroje nic.
* **Hystereze:** alert až po třech vzorcích v řadě (15 s), návrat po šesti (30 s),
  mezi alerty nejméně 10 minut. Zpráva o návratu cooldownu nepodléhá. Ověřeno
  suchým během posloupnosti stavů.

## Instalace

```sh
./install.sh
```

Přeloží, zkopíruje do `~/Applications` a zaregistruje LaunchAgent
(`cz.filipburda.thermalwatch`, `RunAtLoad` + `KeepAlive`), takže jede na pozadí a
nastartuje po přihlášení. Po každé změně kódu spusť `./install.sh` znovu — jinak
běží stará kopie z `~/Applications`. Odinstalace `./uninstall.sh`.

## CLI

```sh
build/thermalwatch --who        # co mi právě teď hřeje stroj
build/thermalwatch --stats 7    # rozpad: co mě za 7 dní nejvíc zpomalovalo
build/thermalwatch --report 60  # retrospektiva poslední hodiny po minutách
build/thermalwatch --once
build/thermalwatch --watch
build/thermalwatch --test-alert
build/thermalwatch --config
```

`--who` dává dvě tabulky: co vytěžuje CPU teď, a co **spálilo nejvíc času
procesoru od svého spuštění**. To druhé je lepší odpověď na „co mi zbytečně hřeje
stroj“ — okamžitá špička může být legitimní build, ale aplikace, která za den
spálila hodinu CPU na pozadí, je kandidát na zavření.

## Push na mobil

1. Nainstaluj ntfy (iOS/Android) a vymysli si **neuhodnutelné** téma, např.
   `thermal-f7k2x9qp` — téma je jediné heslo.
2. Odeber si ho v aplikaci.
3. Zapiš do configu a restartuj agenta:

```sh
open -a TextEdit "$HOME/Library/Application Support/ThermalWatch/config.json"
```

```sh
launchctl kickstart -k "gui/$(id -u)/cz.filipburda.thermalwatch"
```

| klíč | výchozí | co dělá |
|---|---|---|
| `ntfyTopic` | `""` | prázdné = vzdálený kanál vypnutý |
| `ntfyServer` | `https://ntfy.sh` | vlastní instance |
| `panel` | `true` | plovoucí okno |
| `sound` | `true` | zvuk k alertu |
| `cooldownSeconds` | `600` | minimální odstup mezi alerty |
| `alertOnModerate` | `false` | upozorňovat už na `Moderate` |

## Data

`~/Library/Application Support/ThermalWatch/`

* `samples.jsonl` — syrové vzorky, drží se 3 dny (~3 MB/den)
* `hours.jsonl` — hodinové souhrny, **nemažou se** (jednotky MB za rok); z nich
  se počítá `--stats`
* `alerts.log` — kdy a proč alert padl, i potlačené pokusy
* `state.json`, `config.json`

Do repozitářů, se kterými pracuješ, nástroj nezapisuje nic.

## Hranice

* Teplota ve stupních ne — bez `sudo` není odkud.
* GPU throttling se neměří, jen CPU.
* Prvních ~30 s po startu je okno pro vyhlazení neúplné.
* Statistika potřebuje nasbíraná data; `--stats` má smysl až po pár dnech běhu.
