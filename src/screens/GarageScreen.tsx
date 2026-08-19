import { LinearGradient } from 'expo-linear-gradient';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ImageSlot } from '../components/ImageSlot';
import { LiveDot } from '../components/LiveDot';
import { ChevronRightIcon, PlusIcon } from '../components/icons';
import { colors, interFont } from '../theme';
import { usePullUpStore } from '../store';

export default function GarageScreen() {
  const insets = useSafeAreaInsets();
  const driving = usePullUpStore((s) => s.driving);
  const setDriving = usePullUpStore((s) => s.setDriving);

  return (
    <View style={styles.root}>
      <ScrollView
        contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 130 }}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <View>
            <Text style={styles.headerTitle}>Garage</Text>
            <Text style={styles.headerSubtitle}>3 vehicles · 2 build updates this week</Text>
          </View>
          <Pressable style={styles.addCircle}>
            <PlusIcon size={16} />
          </Pressable>
        </View>

        {/* BMW — hero, currently driving */}
        <View style={[styles.card, { marginTop: 22 }]}>
          <View style={{ height: 214 }}>
            <ImageSlot placeholder="Drop a photo of the 320i" />
            <LinearGradient
              pointerEvents="none"
              colors={['rgba(11,12,14,.55)', 'rgba(11,12,14,0)', 'rgba(11,12,14,.9)']}
              locations={[0, 0.34, 1]}
              style={StyleSheet.absoluteFill}
            />
            {driving === 'bmw' ? (
              <View style={styles.drivingBadge}>
                <LiveDot />
                <Text style={styles.drivingBadgeText}>CURRENTLY DRIVING</Text>
              </View>
            ) : null}
            <View style={styles.cardOverlayBottom} pointerEvents="none">
              <Text style={styles.vehicleTitleLarge}>2014 BMW 320i xDrive</Text>
              <Text style={styles.vehicleMeta}>F30 · N20</Text>
            </View>
          </View>
          <View style={styles.chipRow}>
            <Text style={[styles.chip, styles.chipStrong]}>Stage 1</Text>
            <Text style={styles.chip}>aFe Intake</Text>
            <Text style={styles.chip}>VRSF Chargepipe</Text>
            <Text style={styles.chipOutline}>+6</Text>
          </View>
          <View style={styles.cardFooter}>
            <Text style={styles.lastChange}>Chargepipe installed · 2d ago</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
              {driving !== 'bmw' ? (
                <Pressable onPress={() => setDriving('bmw')} style={styles.setDrivingButton}>
                  <Text style={styles.setDrivingText}>Set as driving</Text>
                </Pressable>
              ) : null}
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 5 }}>
                <Text style={styles.buildLink}>Build</Text>
                <ChevronRightIcon color="#fff" size={12} />
              </View>
            </View>
          </View>
        </View>

        {/* GSX-R750 */}
        <View style={[styles.card, { marginTop: 14 }]}>
          <View style={{ height: 162 }}>
            <ImageSlot placeholder="Drop a photo of the GSX-R" />
            <LinearGradient
              pointerEvents="none"
              colors={['rgba(11,12,14,.3)', 'rgba(11,12,14,0)', 'rgba(11,12,14,.88)']}
              locations={[0, 0.4, 1]}
              style={StyleSheet.absoluteFill}
            />
            {driving === 'gsxr' ? (
              <View style={styles.drivingBadge}>
                <LiveDot />
                <Text style={styles.drivingBadgeText}>CURRENTLY RIDING</Text>
              </View>
            ) : null}
            <View style={[styles.cardOverlayBottom, { bottom: 13 }]} pointerEvents="none">
              <Text style={styles.vehicleTitleMed}>2001 Suzuki GSX-R750</Text>
              <Text style={styles.vehicleMeta}>K1</Text>
            </View>
          </View>
          <View style={[styles.chipRow, { paddingTop: 13 }]}>
            <Text style={styles.chip}>Yoshimura R-77</Text>
            <Text style={styles.chip}>Woodcraft rearsets</Text>
            <Text style={styles.chipOutline}>+3</Text>
          </View>
          <View style={styles.cardFooter}>
            <Text style={styles.lastChange}>Fork seals · planned</Text>
            {driving !== 'gsxr' ? (
              <Pressable onPress={() => setDriving('gsxr')} style={styles.setDrivingButton}>
                <Text style={styles.setDrivingText}>Set as driving</Text>
              </Pressable>
            ) : null}
          </View>
        </View>

        {/* RX-7 — compact */}
        <View style={[styles.card, styles.compactCard]}>
          <View style={{ width: 132 }}>
            <ImageSlot />
          </View>
          <View style={styles.compactBody}>
            <Text style={styles.compactTitle}>1994 Mazda RX-7</Text>
            <Text style={styles.compactMeta}>FD3S · 13B-REW</Text>
            <View style={[styles.chipRow, { paddingTop: 10, paddingHorizontal: 0 }]}>
              <Text style={[styles.chip, styles.chipSmall]}>Single turbo</Text>
              <Text style={[styles.chipOutline, styles.chipSmall]}>+4</Text>
            </View>
            <Text style={styles.offRoad}>Off the road · engine out</Text>
          </View>
        </View>

        {/* Add a vehicle */}
        <Pressable style={styles.addTile}>
          <View style={styles.addTileIcon}>
            <PlusIcon size={17} />
          </View>
          <View>
            <Text style={styles.addTileTitle}>Add a vehicle</Text>
            <Text style={styles.addTileSubtitle}>Drop a photo — year, make and model get filled in</Text>
          </View>
        </Pressable>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.screenBg },
  header: { flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 8 },
  headerTitle: { fontFamily: interFont(700), fontSize: 30, color: '#fff', letterSpacing: -0.9, lineHeight: 32 },
  headerSubtitle: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.42)', marginTop: 6, letterSpacing: -0.1 },
  addCircle: { width: 36, height: 36, borderRadius: 18, borderWidth: 1, borderColor: colors.borderStrong, alignItems: 'center', justifyContent: 'center' },

  card: { marginHorizontal: 16, borderRadius: 22, overflow: 'hidden', backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  drivingBadge: { position: 'absolute', top: 13, left: 14, flexDirection: 'row', alignItems: 'center', gap: 7, height: 26, paddingHorizontal: 11, borderRadius: 13, backgroundColor: 'rgba(11,12,14,.62)' },
  drivingBadgeText: { fontFamily: interFont(650), fontSize: 10, letterSpacing: 0.8, color: colors.amber },
  cardOverlayBottom: { position: 'absolute', left: 16, right: 16, bottom: 14 },
  vehicleTitleLarge: { fontFamily: interFont(670), fontSize: 21, color: '#fff', letterSpacing: -0.5, lineHeight: 24 },
  vehicleTitleMed: { fontFamily: interFont(660), fontSize: 19, color: '#fff', letterSpacing: -0.4, lineHeight: 22 },
  vehicleMeta: { fontFamily: interFont(550), fontSize: 12.5, color: 'rgba(255,255,255,.6)', marginTop: 4, letterSpacing: 0.2 },

  chipRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 7, paddingHorizontal: 16, paddingTop: 14 },
  chip: { fontFamily: interFont(600), fontSize: 11.5, color: 'rgba(255,255,255,.8)', backgroundColor: 'rgba(255,255,255,.06)', borderRadius: 11, paddingHorizontal: 10, paddingVertical: 5 },
  chipStrong: { color: '#fff', backgroundColor: 'rgba(255,255,255,.09)' },
  chipOutline: { fontFamily: interFont(600), fontSize: 11.5, color: 'rgba(255,255,255,.5)', borderWidth: 1, borderColor: 'rgba(255,255,255,.12)', borderRadius: 11, paddingHorizontal: 10, paddingVertical: 4 },
  chipSmall: { fontSize: 11, borderRadius: 10, paddingHorizontal: 9, paddingVertical: 4 },

  cardFooter: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingTop: 14, paddingBottom: 15 },
  lastChange: { fontFamily: interFont(400), fontSize: 12, color: 'rgba(255,255,255,.45)', letterSpacing: -0.1, flexShrink: 1 },
  setDrivingButton: { height: 30, justifyContent: 'center', paddingHorizontal: 13, borderRadius: 15, borderWidth: 1, borderColor: colors.borderStrong },
  setDrivingText: { fontFamily: interFont(600), fontSize: 12, color: '#fff', letterSpacing: -0.1 },
  buildLink: { fontFamily: interFont(600), fontSize: 12.5, color: '#fff' },

  compactCard: { flexDirection: 'row', marginTop: 14 },
  compactBody: { flex: 1, minWidth: 0, padding: 15 },
  compactTitle: { fontFamily: interFont(640), fontSize: 15.5, color: '#fff', letterSpacing: -0.3 },
  compactMeta: { fontFamily: interFont(550), fontSize: 11.5, color: 'rgba(255,255,255,.45)', marginTop: 3, letterSpacing: 0.2 },
  offRoad: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.35)', marginTop: 11 },

  addTile: { flexDirection: 'row', alignItems: 'center', gap: 13, marginHorizontal: 16, marginTop: 14, borderRadius: 20, borderWidth: 1, borderStyle: 'dashed', borderColor: colors.borderStrong, padding: 18 },
  addTileIcon: { width: 38, height: 38, borderRadius: 19, backgroundColor: 'rgba(255,255,255,.07)', alignItems: 'center', justifyContent: 'center' },
  addTileTitle: { fontFamily: interFont(620), fontSize: 14, color: '#fff', letterSpacing: -0.2 },
  addTileSubtitle: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.4)', marginTop: 3, letterSpacing: -0.05 },
});
