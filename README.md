# pull-up

A social map and garage app for car and motorcycle enthusiasts.

Expo / React Native (TypeScript) app implementing the Map, Garage, Meets,
Activity, and You screens designed in Claude Design.

## Run it

```
npm install
npm start
```

Then open in Expo Go, or `npm run ios` / `npm run android` with a
simulator.

## Structure

- `src/screens/` — the five tab screens (`MapScreen`, `GarageScreen`,
  `MeetsScreen`, `ActivityScreen`, `YouScreen`)
- `src/components/` — shared UI: `Avatar`, `ImageSlot` (photo-placeholder
  stand-in), `GlassPill` (blurred pill chrome), `Sheet` (bottom sheet),
  `TabBar` (custom bottom nav), map markers/art, icons
- `src/store.ts` — app state (Zustand): selected map marker, sharing mode,
  currently-driving vehicle, unread activity count, plus the mock
  friends/garage/meets data
- `src/theme.ts` — colors and the Inter font-weight helper

The Map screen's markers are placed at fixed design-canvas coordinates and
scaled to the device width via `ScaledCanvas` rather than re-derived as a
flex layout, to stay faithful to the original absolute-position design.

Photo slots (map marker plates, meet/vehicle covers) currently render an
empty placeholder tile — swap `ImageSlot` for a real `<Image>` once photo
upload is wired up.
