import type { BottomTabBarProps } from '@react-navigation/bottom-tabs';
import { LinearGradient } from 'expo-linear-gradient';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { colors, interFont } from '../theme';
import { usePullUpStore } from '../store';
import { TabActivityIcon, TabGarageIcon, TabMapIcon, TabMeetsIcon } from './icons';

const ICONS: Record<string, (color: string) => React.ReactNode> = {
  Map: (color) => <TabMapIcon color={color} />,
  Garage: (color) => <TabGarageIcon color={color} />,
  Meets: (color) => <TabMeetsIcon color={color} />,
  Activity: (color) => <TabActivityIcon color={color} />,
};

export function TabBar({ state, descriptors, navigation }: BottomTabBarProps) {
  const insets = useSafeAreaInsets();
  const unread = usePullUpStore((s) => s.unread);
  const markActivityRead = usePullUpStore((s) => s.markActivityRead);

  return (
    <View style={[styles.wrap, { paddingBottom: insets.bottom + 12, height: 62 + insets.bottom + 12 }]} pointerEvents="box-none">
      <LinearGradient
        pointerEvents="none"
        colors={['rgba(8,9,11,0)', 'rgba(8,9,11,.94)']}
        locations={[0, 0.46]}
        style={StyleSheet.absoluteFill}
      />
      <View style={styles.row}>
        {state.routes.map((route, index) => {
          const { options } = descriptors[route.key];
          const label = (options.title ?? route.name) as string;
          const focused = state.index === index;
          const color = focused ? '#fff' : 'rgba(255,255,255,.5)';

          const onPress = () => {
            if (route.name === 'Activity') markActivityRead();
            const event = navigation.emit({ type: 'tabPress', target: route.key, canPreventDefault: true });
            if (!focused && !event.defaultPrevented) {
              navigation.navigate(route.name);
            }
          };

          return (
            <Pressable key={route.key} onPress={onPress} style={styles.tab}>
              <View>
                {route.name === 'You' ? (
                  <View style={[styles.youAvatar, focused && styles.youAvatarActive]}>
                    <Text style={[styles.youAvatarText, focused && { color: '#fff' }]}>A</Text>
                  </View>
                ) : (
                  ICONS[route.name]?.(color)
                )}
                {route.name === 'Activity' && unread > 0 ? <View style={styles.badge} /> : null}
              </View>
              <Text style={[styles.label, { color: focused ? '#fff' : 'rgba(255,255,255,.5)' }]}>{label}</Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { position: 'absolute', left: 0, right: 0, bottom: 0 },
  row: { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 12 },
  tab: { flex: 1, alignItems: 'center', gap: 4 },
  label: { fontFamily: interFont(600), fontSize: 9.5, letterSpacing: 0.1 },
  badge: { position: 'absolute', top: -1, right: -1, width: 7, height: 7, borderRadius: 4, backgroundColor: colors.amber, borderWidth: 1.5, borderColor: '#0b0c0e' },
  youAvatar: { width: 22, height: 22, borderRadius: 11, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(255,255,255,.35)', alignItems: 'center', justifyContent: 'center', backgroundColor: '#1c2029' },
  youAvatarActive: { borderWidth: 1.5, borderColor: '#fff' },
  youAvatarText: { fontFamily: interFont(650), fontSize: 9, color: 'rgba(255,255,255,.85)' },
});
