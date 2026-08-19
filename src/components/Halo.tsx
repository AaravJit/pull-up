import { useEffect, useRef } from 'react';
import { Animated, StyleSheet } from 'react-native';

interface HaloProps {
  color: string;
  borderRadius: number;
  duration?: number;
  inset?: number;
}

/** Expanding pulse ring behind live markers/location dot — source's @keyframes pu-halo. */
export function Halo({ color, borderRadius, duration = 2600, inset = 0 }: HaloProps) {
  const t = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    const loop = Animated.loop(
      Animated.timing(t, { toValue: 1, duration, useNativeDriver: true })
    );
    loop.start();
    return () => loop.stop();
  }, [t, duration]);

  return (
    <Animated.View
      pointerEvents="none"
      style={[
        StyleSheet.absoluteFill,
        {
          margin: -inset,
          borderRadius,
          backgroundColor: color,
          opacity: t.interpolate({ inputRange: [0, 0.15, 0.7, 1], outputRange: [0.55, 0.5, 0, 0] }),
          transform: [
            {
              scale: t.interpolate({ inputRange: [0, 0.7, 1], outputRange: [0.85, 1.6, 1.6] }),
            },
          ],
        },
      ]}
    />
  );
}
