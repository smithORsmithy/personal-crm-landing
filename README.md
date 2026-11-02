# Лендинг личной CRM

Одна статичная страница. Все кнопки «Открыть мою CRM» ведут в приложение: https://app.linkbook.site

## Запуск у себя

```sh
pnpm install
pnpm dev        # страница с автообновлением: http://localhost:4321
pnpm build      # готовая сборка в папке dist/
pnpm preview    # посмотреть готовую сборку
```

## Где что лежит

- `design/` — макет: `Landing.dc.html` (варианты 2a — телефон, 3a — компьютер) и `README.md` с токенами и текстами
- `src/styles/tokens.css` — все цвета, шрифты, размеры текста и отступы
- `src/sections/` — блоки страницы сверху вниз: шапка, первый экран, проблема, решение, выгоды, призыв, подвал
- `src/components/CtaButton.astro` — кнопка «Открыть мою CRM»
- `src/config.ts` — адрес приложения
- `src/assets/photos/` — фото (Pexels, бесплатная лицензия); при сборке сжимаются в AVIF/WebP
- `public/fonts/` — шрифты Manrope и Marck Script, кириллица и латиница; тексты лицензий (OFL) лежат рядом
- `.github/workflows/deploy.yml` — выкатка на сервер
- `deploy/prepare-server.sh` — общая подготовка сервера: Docker (порты контейнеров только на 127.0.0.1), nginx для `linkbook.site` и `app.linkbook.site` с заглушкой, один сертификат HTTPS на оба домена
- `deploy/setup-landing.sh` — серверная часть выкатки лендинга: пользователь выкатки, папка сайта, настройки nginx для `linkbook.site`

## Выкатка

Сайт: https://linkbook.site

Push в `main` → GitHub Actions собирает `dist/` → `rsync --delete` на сервер → проверка, что главная отвечает 200 и это именно свежая сборка. Ход выкатки — во вкладке Actions на GitHub. Запустить вручную: Actions → Deploy → Run workflow.

Стенда и отката нет: если сломалось — правим и пушим новую версию.

Что лежит в настройках репозитория (Settings → Secrets and variables → Actions):

- секрет `DEPLOY_SSH_KEY` — ключ выкатки; на сервере он может только класть файлы в папку сайта
- переменные `DEPLOY_HOST` (адрес сервера), `DEPLOY_USER` (`deploy-landing`), `DEPLOY_KNOWN_HOSTS` (отпечаток сервера)

## Сервер

Сервер общий с приложением, вход — `ssh crm` (пользователь `crmapp`). Вход под root и по паролю выключен, sudo спрашивает пароль `crmapp`. Скрипты трогают только своё, их можно запускать повторно.

1. `deploy/prepare-server.sh` — один раз на сервер:

   ```sh
   scp deploy/prepare-server.sh crm:
   ssh -t crm "sudo bash ~/prepare-server.sh <почта для Let's Encrypt>"
   ```

2. `deploy/setup-landing.sh` — после него, для выкатки лендинга:

   ```sh
   scp deploy/setup-landing.sh crm:
   ssh -t crm "sudo bash ~/setup-landing.sh '<публичный ключ выкатки>'"
   ```

Что где лежит:

- `/var/www/linkbook.site` — файлы лендинга
- `/var/www/placeholder` — заглушка «Скоро здесь будет сайт»: её показывает домен, пока на нём нет проекта
- `/etc/nginx/sites-available/linkbook.site` и `app.linkbook.site` — настройки nginx для каждого домена
- `/etc/letsencrypt/live/linkbook.site` — один сертификат на оба домена, продлевается сам (таймер `certbot.timer`)
- `/etc/docker/daemon.json` — порты контейнеров открываются только на 127.0.0.1, наружу — через nginx
