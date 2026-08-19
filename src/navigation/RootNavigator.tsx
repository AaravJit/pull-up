import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { DarkTheme, NavigationContainer } from '@react-navigation/native';
import { TabBar } from '../components/TabBar';
import { colors } from '../theme';
import ActivityScreen from '../screens/ActivityScreen';
import GarageScreen from '../screens/GarageScreen';
import MapScreen from '../screens/MapScreen';
import MeetsScreen from '../screens/MeetsScreen';
import YouScreen from '../screens/YouScreen';

const Tab = createBottomTabNavigator();

const navTheme = {
  ...DarkTheme,
  colors: { ...DarkTheme.colors, background: colors.screenBg, card: colors.screenBg },
};

export function RootNavigator() {
  return (
    <NavigationContainer theme={navTheme}>
      <Tab.Navigator
        tabBar={(props) => <TabBar {...props} />}
        screenOptions={{ headerShown: false }}
      >
        <Tab.Screen name="Map" component={MapScreen} />
        <Tab.Screen name="Garage" component={GarageScreen} />
        <Tab.Screen name="Meets" component={MeetsScreen} />
        <Tab.Screen name="Activity" component={ActivityScreen} />
        <Tab.Screen name="You" component={YouScreen} />
      </Tab.Navigator>
    </NavigationContainer>
  );
}
