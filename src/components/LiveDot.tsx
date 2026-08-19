import { useEffect, useRef } from 'react';
import { Animated } from 'react-native';
import { colors } from '../theme';

interface LiveDotProps {
  size?: number;
  color?: string;
}

/** Pulsing live-state dot, matching the source's @keyframes pu-live. */
export function LiveDot({ size = 6, color = colors.amber }: LiveDotProps) {
  const pulse = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: 0.35, duration: 900, useNativeDriver: true }),
        Animated.timing(pulse, { toValue: 1, duration: 900, useNativeDriver: true }),
      ])
    );
    loop.start();
    return () => loop.stop();
  }, [pulse]);

  return (
    <Animated.View
      style={{
        width: size,
        height: size,
        borderRadius: size / 2,
        backgroundColor: color,
        opacity: pulse,
      }}
    />
  );
}
