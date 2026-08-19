export const colors = {
  bg: '#08090b',
  screenBg: '#0b0c0e',
  surface: '#101216',
  surfaceRaised: '#15171b',
  border: 'rgba(255,255,255,.08)',
  borderStrong: 'rgba(255,255,255,.16)',
  amber: '#f2a03d',
  gradientTileFrom: '#262b34',
  gradientTileTo: '#14161a',
};

/**
 * Inter static weight cuts loaded via @expo-google-fonts/inter — the design
 * uses many fine-grained CSS font-weight values (550/620/650/680/etc) that
 * have no matching static font file, so each is bucketed to the nearest
 * loaded cut.
 */
export function interFont(weight: number): string {
  if (weight <= 450) return 'Inter_400Regular';
  if (weight <= 550) return 'Inter_500Medium';
  if (weight <= 630) return 'Inter_600SemiBold';
  return 'Inter_700Bold';
}

// Required by direct file path (not the package's barrel index) so Metro
// only bundles the 4 weight cuts this app actually uses, not all 18.
export const Inter_400Regular = require('@expo-google-fonts/inter/400Regular/Inter_400Regular.ttf');
export const Inter_500Medium = require('@expo-google-fonts/inter/500Medium/Inter_500Medium.ttf');
export const Inter_600SemiBold = require('@expo-google-fonts/inter/600SemiBold/Inter_600SemiBold.ttf');
export const Inter_700Bold = require('@expo-google-fonts/inter/700Bold/Inter_700Bold.ttf');
