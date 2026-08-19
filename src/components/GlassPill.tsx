import { BlurView } from 'expo-blur';
import { StyleSheet, View, ViewStyle } from 'react-native';

interface GlassPillProps {
  style?: ViewStyle;
  intensity?: number;
  tint?: 'light' | 'dark' | 'default';
  children?: React.ReactNode;
  borderColor?: string;
}

/**
 * The frosted rounded pills used across the map chrome (search bar, sharing
 * pill, vehicle selector) — a blur layer under a translucent tint + hairline
 * border, matching the source's background:rgba(...)+backdrop-filter:blur().
 */
export function GlassPill({ style, intensity = 40, tint = 'dark', children, borderColor = 'rgba(255,255,255,.09)' }: GlassPillProps) {
  return (
    <View style={[styles.clip, style, { borderColor, borderWidth: 1 }]}>
      <BlurView intensity={intensity} tint={tint} style={StyleSheet.absoluteFill} />
      <View style={[styles.tint, { borderRadius: (style?.borderRadius as number) ?? 19 }]} />
      <View style={styles.content}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  clip: {
    overflow: 'hidden',
  },
  tint: {
    ...StyleSheet.absoluteFill,
    backgroundColor: 'rgba(16,18,21,.45)',
  },
  content: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
  },
});
