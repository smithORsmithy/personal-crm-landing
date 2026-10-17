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
