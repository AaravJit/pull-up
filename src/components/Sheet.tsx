import { useEffect, useRef } from 'react';
import { Animated, Pressable, StyleSheet, ViewStyle } from 'react-native';
import { colors } from '../theme';

interface SheetProps {
  visible: boolean;
  onDismiss: () => void;
  children?: React.ReactNode;
  style?: ViewStyle;
}

/** Slide-up sheet + tap-to-dismiss scrim, matching the source's pu-rise animation. */
export function Sheet({ visible, onDismiss, children, style }: SheetProps) {
  const rise = useRef(new Animated.Value(0)).current;
  const scrim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.timing(rise, {
        toValue: visible ? 1 : 0,
        duration: visible ? 380 : 220,
        useNativeDriver: true,
      }),
      Animated.timing(scrim, {
        toValue: visible ? 1 : 0,
        duration: visible ? 350 : 220,
        useNativeDriver: true,
      }),
    ]).start();
  }, [visible, rise, scrim]);

  if (!visible) {
    return (
      <Animated.View pointerEvents="none" style={[styles.scrim, { opacity: scrim }]} />
    );
  }

  return (
    <>
      <Pressable style={StyleSheet.absoluteFill} onPress={onDismiss}>
        <Animated.View style={[styles.scrim, { opacity: scrim }]} />
      </Pressable>
      <Animated.View
        style={[
          styles.sheet,
          style,
          {
            transform: [
              {
                translateY: rise.interpolate({ inputRange: [0, 1], outputRange: [26, 0] }),
              },
            ],
            opacity: rise,
          },
        ]}
      >
        {children}
      </Animated.View>
    </>
  );
}

const styles = StyleSheet.create({
  scrim: {
    ...StyleSheet.absoluteFill,
    backgroundColor: 'rgba(6,7,9,.5)',
  },
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: colors.surface,
    borderTopLeftRadius: 26,
    borderTopRightRadius: 26,
    borderTopWidth: 1,
    borderColor: 'rgba(255,255,255,.09)',
    overflow: 'hidden',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: -20 },
    shadowOpacity: 0.6,
    shadowRadius: 60,
    elevation: 24,
  },
});
