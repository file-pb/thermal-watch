# ThermalWatch

Indikátor v menu baru, který odpovídá na jednu otázku: **omezuje mě teď teplota
Macu, nebo to drhne z jiného důvodu?** Bez `sudo`, bez instalace čehokoli dalšího
než Command Line Tools.

```
● 97 %     ← v menu baru: barva = stav, číslo = efektivní rychlost jádra
```

Po rozkliknutí: verdikt s příčinou, graf posledních 30 minut a podíl času
s omezením. Historie je tam proto, aby šlo zpětně říct „ve 14:32, když to stálo,
byla rychlost 61 % a tepelný stav serious“.

## Co se měří a proč zrovna tohle

Na tomhle stroji (M5, `Mac17,3`, macOS 27) jsem prošel obvyklé zdroje:

| zdroj | výsledek |
|---|---|
| `pmset -g therm` | `No CPU power status has been recorded` – `CPU_Speed_Limit` je dědictví Intelu, na Apple Silicon se neplní |
| `pmset -g thermlog` | prázdné |
| `sysctl -a \| grep -i thermal` | nic |
| `powermetrics -s smc,thermal` | `must be invoked as the superuser` |
| `ioreg -c AppleSMC` | třídy `AppleARMPMUTempSensor` existují, ale teplotu v properties nevystavují – čtení čidel jde jen přes privátní `IOHIDEventSystem` |
| `ioreg -r -c AppleSmartBattery` | napětí, proud, cykly; teplotu ne |

Bez `sudo` tedy **teplota ve stupních k dispozici není**. Zbývají dvě věci, a ty
dohromady stačí:

1. **`ProcessInfo.thermalState`** – systémový tepelný tlak (`nominal` → `fair` →
   `serious` → `critical`). Apple k `serious` říká „system performance may be
   reduced“, takže to je okamžik, kdy throttling skutečně běží. Veřejné API, bez
   oprávnění. (`src/Sampler.swift`, `Verdict.thermalLevel`)
2. **Efektivní rychlost jádra** – měřená, ne odhadovaná: referenční smyčka
   (300 000 iterací FP) se spustí v dávkách a bere se nejlepší čas. Vydělený
   kalibrovaným minimem dá procenta. Tohle je náhrada za chybějící
   `CPU_Speed_Limit`.

Verdikt obě čísla spojuje a hlavně **pojmenuje příčinu** – `Verdict.cause()`:
tepelný tlak, zátěž CPU (podle `load average`), Low Power Mode, nebo pokles bez
zjevného důvodu. To je přesně to, co odliší „Mac se dusí“ od „běží mi čtrnáct
procesů“.

## Tři věci, které měření rozbíjely (a jsou v kódu ošetřené)

Měřená zjištění, ne obavy – každé stálo jeden chybný výsledek:

* **Optimalizátor smyčku odstranil.** S `-O` vracelo měření 0 ns, protože devět
  volání čisté funkce se stejnými argumenty Swift sloučí do jednoho (CSE) a
  zbytek změří nulu. Seed se proto bere z časovače a výsledek se sčítá do globální
  proměnné. `src/Sampler.swift` → `burstNanos()`.
* **Rozjezd frekvence.** Vlákno, které 5 s spí a pak 4 ms počítá, dostane na
  Apple Silicon nízkou frekvenci – DVFS se řídí historií dané thread group.
  Naměřeno ve dvou sériích: warmup 0,8 ms → 640/622 µs, 4 ms → 628/616 µs,
  10 ms → 393/396 µs, 80 ms → 396/380 µs. Bez warmupu měření neukazuje
  throttling, ale vlastní rozjezd. Proto `Sampler.warmups = 30` dávek ≈ 12 ms.
* **Jeden vzorek je šum.** I na nečinném stroji minimum kolísá o desítky procent.
  Verdikt proto bere nejlepší hodnotu z okna 30 s (`Verdict.smoothSeries`) – když
  ani ta není dobrá, omezení je skutečné. Graf kreslí tuhle vyhlazenou řadu, surové
  číslo zůstává v řádku s detailem.

## Co to stojí

Jeden vzorek = `Sampler.warmups` + `Sampler.bursts` = 40 dávek po ~0,4 ms, tedy
**~16 ms práce jednoho jádra každých 5 s** (interval v `src/App.swift`,
`private let interval: TimeInterval = 5`). To je 0,3 % jednoho jádra, na desetijádru
0,03 % stroje. V `ps` se aplikace drží na 0,0 % CPU a ~50 MB RSS.

## Instalace

```sh
./install.sh
```

Přeloží to, zkopíruje `ThermalWatch.app` do `~/Applications` a zaregistruje
LaunchAgent, takže se spustí i po přihlášení. Odinstalace `./uninstall.sh`
(data nechá být).

Jen přeložit, bez instalace: `./build.sh`, pak `open build/ThermalWatch.app`.

## CLI

```sh
build/thermalwatch --once            # jeden odečet
build/thermalwatch --watch           # průběžně v terminálu, sparkline za 30 min
build/thermalwatch --report 60       # retrospektiva: kdy to vázlo a proč
build/thermalwatch --chart graf.png 30
```

`--report` je ta odpověď na „zaseklo se mi to ve 14:32“: vypíše minuty s omezením,
u každé rychlost, tepelný stav a load.

## Data

`~/Library/Application Support/ThermalWatch/`

* `samples.jsonl` – jeden řádek na vzorek, při startu se zkracuje na 48 h
* `state.json` – kalibrované minimum (100 %)

Do repozitářů, se kterými pracuješ, nástroj nezapisuje nic.

## Kalibrace

Při prvním spuštění se změří referenční minimum. Dál se zpřesňuje na nejlepší kdy
viděný čas (`App.tick`), takže se časem usadí. Když vyjde zjevně mimo – třeba
kalibrace proběhla během buildu – je v menu *Překalibrovat 100 %*.

## Hranice toho, co to umí

* Teplotu ve stupních ne. Bez `sudo` není odkud ji vzít (viz tabulka výše). Kdyby
  byla potřeba, jde přidat `sudoers` pravidlo pro `powermetrics` a dočíst
  `CPU die temperature` – záměrně to tu není, protože na otázku „omezuje mě to“
  odpovídá hůř než měřená rychlost.
* Prvních ~30 s po startu je okno pro vyhlazení neúplné, takže verdikt může být
  zbytečně přísný.
* GPU throttling se neměří, jen CPU.
