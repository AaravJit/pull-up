import { LinearGradient } from 'expo-linear-gradient';
import { StyleSheet, Text, View, ViewStyle } from 'react-native';
import { colors, interFont } from '../theme';

interface AvatarProps {
  size: number;
  radius?: number;
  label: string;
  fontSize?: number;
  border?: string;
  borderWidth?: number;
  style?: ViewStyle;
  textColor?: string;
}

export function Avatar({
  size,
  radius,
  label,
  fontSize,
  border,
  borderWidth = 1,
  style,
  textColor = 'rgba(255,255,255,.85)',
}: AvatarProps) {
  const r = radius ?? size / 2;
  return (
    <View
      style={[
        {
          width: size,
          height: size,
          borderRadius: r,
          overflow: 'hidden',
          borderColor: border,
          borderWidth: border ? borderWidth : 0,
        },
        style,
      ]}
    >
      <LinearGradient
        colors={[colors.gradientTileFrom, colors.gradientTileTo]}
        start={{ x: 0.15, y: 0 }}
        end={{ x: 0.85, y: 1 }}
        style={styles.fill}
      >
        <Text
          style={{
            fontFamily: interFont(650),
            fontSize: fontSize ?? size * 0.32,
            color: textColor,
          }}
        >
          {label}
        </Text>
      </LinearGradient>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: {
    width: '100%',
    height: '100%',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
