import { StyleSheet, Text, View, ViewStyle } from 'react-native';
import { colors, interFont } from '../theme';

interface ImageSlotProps {
  placeholder?: string;
  style?: ViewStyle;
  children?: React.ReactNode;
}

/**
 * Stand-in for a user-uploaded photo. The design ships with empty photo
 * slots throughout (map markers, sheets, garage cards) — this renders the
 * same neutral empty-state tile the source uses (--is-bg:#15171b), ready to
 * swap for a real <Image> once photo upload is wired up.
 */
export function ImageSlot({ placeholder, style, children }: ImageSlotProps) {
  return (
    <View style={[styles.base, style]}>
      {children}
      {placeholder ? (
        <Text style={styles.caption} numberOfLines={1}>
          {placeholder}
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  base: {
    width: '100%',
    height: '100%',
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  caption: {
    fontFamily: interFont(500),
    fontSize: 11,
    color: 'rgba(255,255,255,.25)',
    paddingHorizontal: 10,
    textAlign: 'center',
  },
});
