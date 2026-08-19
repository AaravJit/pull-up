import { StyleSheet, View, useWindowDimensions } from 'react-native';

interface ScaledCanvasProps {
  designWidth?: number;
  children?: React.ReactNode;
}

/**
 * The Map screen's markers are placed at fixed pixel coordinates against a
 * 402pt-wide design canvas (the iPhone frame the design was built in).
 * Scaling the whole canvas uniformly to the real device width keeps every
 * marker's position faithful across screen sizes instead of re-deriving a
 * flex layout for absolutely-placed map pins.
 */
export function ScaledCanvas({ designWidth = 402, children }: ScaledCanvasProps) {
  const { width, height } = useWindowDimensions();
  const scale = width / designWidth;

  return (
    <View style={styles.clip}>
      <View
        style={{
          width: designWidth,
          height: height / scale,
          transform: [{ scale }],
          transformOrigin: '0 0',
        }}
      >
        {children}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  clip: {
    flex: 1,
    overflow: 'hidden',
  },
});
