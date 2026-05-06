# F5GO OpenWrt Dumb AP Configurator

![OpenWrt](https://img.shields.io/badge/OpenWrt-Dumb_AP-blue?style=for-the-badge&logo=openwrt)
![Shell](https://img.shields.io/badge/Language-Shell-green?style=for-the-badge&logo=gnu-bash)
![Platform](https://img.shields.io/badge/Launcher-macOS%20%7C%20Windows-orange?style=for-the-badge)

Короткий набор скриптов для перевода OpenWrt в режим **Dumb AP**  (мост + отключение DHCP + настройка Wi-Fi) и быстрого запуска с macOS/Windows.

---

## Основная логика

`f5go-openwrt-dumb-ap.sh` по шагам:

1. Определяет шлюз и предлагает IP для точки доступа.
2. Запрашивает параметры сети и Wi-Fi (SSID/пароль, единый или раздельный SSID).
3. Собирает LAN/WAN порты и формирует мост `br-lan`.
4. Удаляет WAN-секции (`wan`, `wan6`, `wan*`) из `network`.
5. Настраивает `network.lan` как `static` (IP, маска, gateway, DNS).
6. Отключает DHCP/RA/DHCPv6/NDP на AP.
7. Поднимает Wi-Fi AP на найденных радио, привязывает к `lan`.
8. Применяет `uci commit` и перезапускает сетевые сервисы.

---

## Файлы Запуска

`run-openwrt-ap.sh` (macOS/Linux) и `run-openwrt-ap.ps1` (Windows):

- спрашивают IP роутера, SSH-логин и порт;
- копируют `f5go-openwrt-dumb-ap.sh` в `/tmp` роутера;
- выдают права и запускают скрипт по SSH.

Поведение при отсутствии локального файла:

- сначала ищут `f5go-openwrt-dumb-ap.sh` рядом с launcher-файлом;
- если файла нет, пытаются скачать его из репозитория: `https://github.com/F5GO/F5GO-OpenWrt-Dumb-AP-Configurator`.

---

## Быстрый Запуск На OpenWrt

Если на роутере есть интернет, запусти под `root` одной командой:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/F5GO/F5GO-OpenWrt-Dumb-AP-Configurator/main/f5go-openwrt-dumb-ap.sh)"
```

> [!NOTE]
> Если путь в GitHub изменится, замени URL на актуальный.

---

## Запуск С Mac И Windows

Сначала скачай файлы на компьютер. Рекомендуется скачать весь репозиторий или GitHub Release целиком, чтобы потом запускать даже без интернета.

Репозиторий:

- `https://github.com/F5GO/F5GO-OpenWrt-Dumb-AP-Configurator`
- `README.md`: `https://github.com/F5GO/F5GO-OpenWrt-Dumb-AP-Configurator/blob/main/README.md`

Минимальный набор:

- `f5go-openwrt-dumb-ap.sh`
- `run-openwrt-ap.sh`
- `run-openwrt-ap.ps1`

После скачивания и распаковки перейди в каталог с файлами `run-openwrt-ap.sh` и `f5go-openwrt-dumb-ap.sh`.

macOS/Linux (пример для папки Downloads):

```bash
cd ~/Downloads/F5GO-OpenWrt-Dumb-AP-Configurator-main
chmod +x run-openwrt-ap.sh
./run-openwrt-ap.sh
```

Windows PowerShell (пример для папки Downloads):

```powershell
cd "$HOME\Downloads\F5GO-OpenWrt-Dumb-AP-Configurator-main"
.\run-openwrt-ap.ps1
```

Если после распаковки имя папки отличается, замени только последний сегмент пути на фактический.

> [!IMPORTANT]
> Windows launcher проверяет `ssh/scp`. Если OpenSSH Client отсутствует, скрипт пытается установить его автоматически. Для авто-установки нужен PowerShell с правами администратора.

##  Контакты 

Проект создан и развивается при поддержке сообщества **F5GO.ONE**.

*   **YouTube:** [F5](https://youtube.com/@F5GO)
*   **Сайт:** [F5GO.ONE](https://f5go.one)
*   **Telegram:** [F5GO](https://t.me/f5gou)

---

> [!IMPORTANT]
> **Лицензия MIT.** Данное программное обеспечение предоставляется «как есть». Используйте его на свой страх и риск.
