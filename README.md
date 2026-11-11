# ThermalWatch

Upozorní tě, **když tě Mac začne zpomalovat teplem** — i když se na nic nedíváš,
pracuješ na celou obrazovku nebo jsi u telefonu. Bez `sudo`, bez účtu, bez
závislostí nad rámec Command Line Tools.

Primární výstup je alert, ne dashboard. Menu bar a graf jsou doplněk pro
retrospektivu („ve 14:32 to stálo — co bylo tehdy?“).

## Co alert umí

* **Plovoucí okno**, které je vidět i nad aplikací na celou obrazovku — vybral
  jsem ho proto, že `display notification` se při Focusu a ve full-screenu schová
  do Centra oznámení, tedy přesně tehdy, kdy se vibecoduje. Panel neukradne fokus
  z editoru (`.nonactivatingPanel`) a má tlačítko *Ztlumit na hodinu*.
* **Co stroj hřeje:** vedle stavu ukáže tři nejžravější procesy podle CPU, takže
  je rovnou vidět akce („zavři simulátor“), ne jen varování.
* **Push na mobil** přes [ntfy.sh](https://ntfy.sh) — zdarma, bez účtu, stačí si
  v aplikaci odebírat zvolené téma. Je to **volitelné**: dokud je `ntfyTopic`
  prázdné, ze stroje neodchází nic a lokální panel funguje sám.
* **Hystereze místo spamu:** alert až po třech vzorcích v řadě (15 s), návrat po
  šesti (30 s), mezi dvěma alerty nejméně 10 minut. Zpráva o návratu do normálu
  cooldownu nepodléhá — ta musí dorazit vždy, jinak nevíš, že můžeš pokračovat.
  Ověřeno suchým během posloupnosti stavů, ne jen přečtením kódu.

## Metrika: Darwin notify klíč, ne `ProcessInfo`

```
notifyutil -g com.apple.system.thermalpressurelevel   →  2
```

Hodnoty 0–4 jsou `Nominal`, `Moderate`, `Heavy`, `Trapping`, `Sleeping` — škála je
z hlavičky SDK na tomhle stroji,
`/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/usr/include/libkern/OSThermalNotification.h`,
větev `#if TARGET_OS_OSX` (druhá větev s 10/20/30/40/50 je iOS). **Heavy a výš =
systém reálně omezuje výkon.** Čtení nevyžaduje root; v kódu přes `notify_register_check`
+ `notify_get_state` (`src/Pressure.swift`).

Dvě slepé uličky, obě ověřené spuštěním na tomhle M5:

| zdroj | výsledek |
|---|---|
| `pmset -g therm` | `No CPU power status has been recorded` — `CPU_Speed_Limit` je intelovský mechanismus, na Apple Silicon mrtvý |
| `pmset -g thermlog` | prázdné |
| `sysctl -a \| grep -i thermal` | nic |
| `powermetrics -s smc,thermal` | `must be invoked as the superuser` |
| `ioreg -c AppleSMC` | `AppleARMPMUTempSensor` teplotu v properties nevystavuje |
| `ioreg -r -c AppleSmartBattery` | napětí, proud, cykly; teplotu ne |

A hlavně past: **`ProcessInfo.thermalState` throttling maskuje.** Ve stejném
okamžiku, kdy notify klíč hlásil `2` (Heavy), vracelo veřejné API `fair` — slévá
`Moderate` a `Heavy` do jedné hodnoty, takže nerozliší zahřátý stroj od omezeného.
Verdikt na něm proto nestojí; hodnota se do záznamu ukládá jen jako doklad rozdílu.

Druhý, doplňkový signál je **měřená efektivní rychlost jádra**: referenční smyčka
v dávkách, bere se nejlepší čas proti kalibrovanému minimu. Říká *o kolik* je to
pomalejší a odliší teplo od obyčejného zahlcení CPU (`Verdict.cause()` to pojmenuje:
teplo / zátěž CPU podle load average / Low Power Mode).

## Tři věci, které měření rychlosti rozbíjely

Měřená zjištění, každé stálo jeden chybný výsledek:

* **Optimalizátor smyčku odstranil.** S `-O` vracelo měření 0 ns: devět volání čisté
  funkce se stejnými argumenty Swift sloučí do jednoho (CSE). Seed se proto bere
  per-call z časovače. `src/Sampler.swift` → `burstNanos()`.
* **Rozjezd frekvence.** Vlákno, které 5 s spí a pak 4 ms počítá, dostane nízkou
  frekvenci — DVFS se na Apple Silicon řídí historií thread group. Naměřeno ve dvou
  sériích: warmup 0,8 ms → 640/622 µs, 4 ms → 628/616 µs, 10 ms → 393/396 µs,
  80 ms → 396/380 µs. Bez warmupu to neměří throttling, ale vlastní rozjezd. Proto
  `Sampler.warmups = 30` dávek ≈ 12 ms.
* **Jeden vzorek je šum.** Verdikt bere nejlepší hodnotu z okna 30 s
  (`Verdict.smoothSeries`); tepelný tlak se ale bere nejhorší z okna, protože to je
  fakt od systému, ne odhad.

## Co to stojí

Jeden vzorek = `Sampler.warmups + Sampler.bursts` = 40 dávek po ~0,4 ms, tedy
**~16 ms práce jednoho jádra každých 5 s** (interval v `src/App.swift`,
`private let interval: TimeInterval = 5`): 0,3 % jednoho jádra, 0,03 % desetijádra.
V `ps` se aplikace drží na 0,0 % CPU a ~50 MB RSS. `ps` na procesy se spouští jen
při alertu, ne při každém vzorku.

## Instalace

```sh
./install.sh
```

Přeloží to, zkopíruje `ThermalWatch.app` do `~/Applications` a zaregistruje
LaunchAgent (`~/Library/LaunchAgents/cz.filipburda.thermalwatch.plist`,
`RunAtLoad` + `KeepAlive`), takže to jede na pozadí a nastartuje po přihlášení.
Odinstalace `./uninstall.sh` — data nechá být.

## Push na mobil (volitelné)

1. Nainstaluj si ntfy ([iOS](https://apps.apple.com/app/ntfy/id1625396347) /
   Android) a vymysli si **neuhodnutelné** téma, např. `thermal-f7k2x9qp` — téma je
   jediné heslo, kdo ho zná, čte tvoje zprávy.
2. V aplikaci si ho odeber.
3. Zapiš ho do configu a restartuj agenta:

```sh
open -a TextEdit "$HOME/Library/Application Support/ThermalWatch/config.json"
```

```sh
launchctl kickstart -k "gui/$(id -u)/cz.filipburda.thermalwatch"
```

Ověř:

```sh
~/Developer/GitHub/thermal-watch/build/thermalwatch --test-alert
```

Config (`--config` vypíše cestu i obsah):

| klíč | výchozí | co dělá |
|---|---|---|
| `ntfyTopic` | `""` | prázdné = vzdálený kanál vypnutý, nic neodchází |
| `ntfyServer` | `https://ntfy.sh` | vlastní instance, když chceš |
| `panel` | `true` | plovoucí okno |
| `sound` | `true` | zvuk k alertu |
| `cooldownSeconds` | `600` | minimální odstup mezi alerty |
| `alertOnModerate` | `false` | upozorňovat už na `Moderate` |

## CLI

```sh
build/thermalwatch --once            # jeden odečet
build/thermalwatch --watch           # průběžně v terminálu
build/thermalwatch --report 60       # retrospektiva: kdy to vázlo a proč
build/thermalwatch --chart graf.png 30
build/thermalwatch --test-alert      # zkušební alert do obou kanálů
build/thermalwatch --config
```

## Data

`~/Library/Application Support/ThermalWatch/`

* `samples.jsonl` — vzorek na řádek, při startu zkráceno na 48 h
* `alerts.log` — kdy a proč alert padl (i potlačené pokusy)
* `state.json` — kalibrované minimum, `config.json` — nastavení

Do repozitářů, se kterými pracuješ, nástroj nezapisuje nic.

## Hranice

* **Teplota ve stupních ne.** Bez `sudo` není odkud (viz tabulka). Na otázku
  „omezuje mě to“ odpovídá tlak lépe než stupně.
* **Kalibrace 100 % může být zkreslená**, když proběhla ve chvíli, kdy stroj už byl
  na `Heavy` — pak je „100 %“ throttlovaná rychlost. Proto je v menu *Překalibrovat
  100 %*; dělej to, když je `--once` na `Nominal`. Verdikt tím netrpí, ten stojí
  na tlaku.
* GPU throttling se neměří, jen CPU.
* Prvních ~30 s po startu je okno pro vyhlazení neúplné.
