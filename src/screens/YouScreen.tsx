import { LinearGradient } from 'expo-linear-gradient';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Avatar } from '../components/Avatar';
import { ImageSlot } from '../components/ImageSlot';
import { LiveDot } from '../components/LiveDot';
import { ChevronRightIcon, PinIcon, SettingsIcon } from '../components/icons';
import { colors, interFont } from '../theme';
import { garage, usePullUpStore } from '../store';

export default function YouScreen() {
  const insets = useSafeAreaInsets();
  const driving = usePullUpStore((s) => s.driving);
  const sharing = usePullUpStore((s) => s.sharing);
  const sharingLabel = sharing === 'Off' ? 'Off' : `${sharing} · ends automatically`;

  return (
    <View style={styles.root}>
      <ScrollView
        contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 130 }}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.headerRow}>
          <Pressable style={styles.editProfilePill}>
            <Text style={styles.editProfileText}>Edit profile</Text>
          </Pressable>
          <Pressable style={styles.iconCircle}>
            <SettingsIcon size={16} color="rgba(255,255,255,.75)" />
          </Pressable>
        </View>

        <View style={styles.identityRow}>
          <Avatar size={76} radius={38} label="A" fontSize={26} border={colors.border} />
          <View style={{ flex: 1, minWidth: 0 }}>
            <Text style={styles.name}>Aarav</Text>
            <Text style={styles.handle}>@aarav.jit · Sacramento</Text>
            <View style={styles.crewRow}>
              <Text style={[styles.crewChip, styles.crewChipStrong]}>Night Shift</Text>
              <Text style={styles.crewChip}>Delta Cruisers</Text>
            </View>
          </View>
        </View>

        <Text style={styles.bio}>Midtown lots and backroads. Slow build, loud enough.</Text>

        <View style={styles.statsRow}>
          <Stat value="148" label="friends" />
          <Stat value="3" label="vehicles" />
          <Stat value="26" label="meets" />
        </View>

        <View style={styles.drivingCard}>
          <View style={{ height: 196 }}>
            <ImageSlot placeholder="Currently driving photo" />
            <LinearGradient
              pointerEvents="none"
              colors={['rgba(11,12,14,.5)', 'rgba(11,12,14,0)', 'rgba(11,12,14,.92)']}
              locations={[0, 0.34, 1]}
              style={StyleSheet.absoluteFill}
            />
            <View style={styles.drivingBadge}>
              <LiveDot />
              <Text style={styles.drivingBadgeText}>CURRENTLY DRIVING</Text>
            </View>
            <View style={styles.drivingOverlay} pointerEvents="none">
              <Text style={styles.drivingTitle}>{garage[driving].name}</Text>
              <Text style={styles.drivingSubtitle}>Stage 1 · aFe Intake · VRSF Chargepipe</Text>
            </View>
          </View>
        </View>

        <View style={styles.garageHeaderRow}>
          <Text style={styles.sectionLabel}>GARAGE</Text>
          <Pressable style={styles.openGarageLink}>
            <Text style={styles.openGarageText}>Open Garage</Text>
            <ChevronRightIcon />
          </Pressable>
        </View>

        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.garageStrip}>
          <GarageStripCard tag="F30" title="2014 BMW 320i" meta="12 mods" />
          <GarageStripCard tag="K1" title="2001 GSX-R750" meta="5 mods" />
          <GarageStripCard tag="FD3S" title="1994 Mazda RX-7" meta="Engine out" />
        </ScrollView>

        <Text style={[styles.sectionLabel, { paddingTop: 28 }]}>RECENTLY</Text>
        <View style={{ marginTop: 8 }}>
          <RecentRow title="Installed the VRSF chargepipe" detail="320i build · 2 photos" time="2d" />
          <RecentRow title="Pulled up to Sac Nights" detail="Sutter Lot · with Maya, Kenji" time="1w" />
          <RecentRow title="Hosted a Night Shift cruise" detail="Delta backroads · 14 pulled up" time="3w" initials="NS" />
        </View>

        <Pressable style={styles.settingsRow}>
          <View style={styles.settingsIconCircle}>
            <PinIcon size={15} />
          </View>
          <View style={{ flex: 1, minWidth: 0 }}>
            <Text style={styles.settingsTitle}>Location sharing</Text>
            <Text style={styles.settingsSubtitle}>{sharingLabel}</Text>
          </View>
          <ChevronRightIcon />
        </Pressable>

        <Pressable style={[styles.settingsRow, { marginTop: 10 }]}>
          <View style={styles.settingsIconCircle}>
            <SettingsIcon size={15} />
          </View>
          <View style={{ flex: 1, minWidth: 0 }}>
            <Text style={styles.settingsTitle}>Settings</Text>
            <Text style={styles.settingsSubtitle}>Notifications, account, blocked</Text>
          </View>
          <ChevronRightIcon />
        </Pressable>
      </ScrollView>
    </View>
  );
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'baseline', gap: 5 }}>
      <Text style={styles.statValue}>{value}</Text>
      <Text style={styles.statLabel}>{label}</Text>
    </View>
  );
}

function GarageStripCard({ tag, title, meta }: { tag: string; title: string; meta: string }) {
  return (
    <View style={{ width: 132 }}>
      <View style={styles.garageStripTile}>
        <Text style={styles.garageStripTag}>{tag}</Text>
      </View>
      <Text style={styles.garageStripTitle}>{title}</Text>
      <Text style={styles.garageStripMeta}>{meta}</Text>
    </View>
  );
}

function RecentRow({ title, detail, time, initials }: { title: string; detail: string; time: string; initials?: string }) {
  return (
    <Pressable style={styles.recentRow}>
      {initials ? (
        <View style={styles.recentInitials}>
          <Text style={styles.recentInitialsText}>{initials}</Text>
        </View>
      ) : (
        <View style={styles.recentThumb} />
      )}
      <View style={{ flex: 1, minWidth: 0 }}>
        <Text style={styles.recentTitle}>{title}</Text>
        <Text style={styles.recentDetail}>{detail}</Text>
      </View>
      <Text style={styles.recentTime}>{time}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.screenBg },
  headerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'flex-end', gap: 8, paddingHorizontal: 20, paddingTop: 8 },
  editProfilePill: { height: 34, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 13, borderRadius: 17, borderWidth: 1, borderColor: colors.border },
  editProfileText: { fontFamily: interFont(600), fontSize: 12.5, color: 'rgba(255,255,255,.8)', letterSpacing: -0.1 },
  iconCircle: { width: 34, height: 34, borderRadius: 17, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center' },

  identityRow: { flexDirection: 'row', alignItems: 'center', gap: 15, paddingHorizontal: 20, paddingTop: 18 },
  name: { fontFamily: interFont(680), fontSize: 23, color: '#fff', letterSpacing: -0.6, lineHeight: 26 },
  handle: { fontFamily: interFont(400), fontSize: 13, color: 'rgba(255,255,255,.42)', marginTop: 3, letterSpacing: -0.1 },
  crewRow: { flexDirection: 'row', gap: 6, marginTop: 10 },
  crewChip: { fontFamily: interFont(600), fontSize: 11, color: 'rgba(255,255,255,.65)', borderWidth: 1, borderColor: colors.borderStrong, borderRadius: 11, paddingHorizontal: 10, paddingVertical: 4 },
  crewChipStrong: { color: '#fff', backgroundColor: 'rgba(255,255,255,.09)', borderWidth: 0, paddingVertical: 5 },

  bio: { fontFamily: interFont(400), fontSize: 13.5, color: 'rgba(255,255,255,.62)', paddingHorizontal: 20, paddingTop: 16, lineHeight: 19.5, letterSpacing: -0.1 },

  statsRow: { flexDirection: 'row', gap: 18, paddingHorizontal: 20, paddingTop: 16 },
  statValue: { fontFamily: interFont(660), fontSize: 14.5, color: '#fff' },
  statLabel: { fontFamily: interFont(400), fontSize: 12, color: 'rgba(255,255,255,.4)' },

  drivingCard: { marginHorizontal: 16, marginTop: 24, borderRadius: 22, overflow: 'hidden', backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  drivingBadge: { position: 'absolute', top: 13, left: 14, flexDirection: 'row', alignItems: 'center', gap: 7, height: 26, paddingHorizontal: 11, borderRadius: 13, backgroundColor: 'rgba(11,12,14,.62)' },
  drivingBadgeText: { fontFamily: interFont(650), fontSize: 10, letterSpacing: 0.8, color: colors.amber },
  drivingOverlay: { position: 'absolute', left: 16, right: 16, bottom: 14 },
  drivingTitle: { fontFamily: interFont(670), fontSize: 21, color: '#fff', letterSpacing: -0.5, lineHeight: 24 },
  drivingSubtitle: { fontFamily: interFont(550), fontSize: 12.5, color: 'rgba(255,255,255,.6)', marginTop: 4, letterSpacing: 0.2 },

  garageHeaderRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 26 },
  sectionLabel: { fontFamily: interFont(650), fontSize: 11, letterSpacing: 1.1, color: 'rgba(255,255,255,.34)' },
  openGarageLink: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  openGarageText: { fontFamily: interFont(600), fontSize: 12.5, color: '#fff' },

  garageStrip: { gap: 10, paddingHorizontal: 16, paddingTop: 14 },
  garageStripTile: { height: 94, borderRadius: 14, backgroundColor: '#1c2029', justifyContent: 'flex-end', padding: 9 },
  garageStripTag: { fontFamily: interFont(650), fontSize: 9, letterSpacing: 0.8, color: 'rgba(255,255,255,.4)' },
  garageStripTitle: { fontFamily: interFont(620), fontSize: 12.5, color: '#fff', marginTop: 8, letterSpacing: -0.2 },
  garageStripMeta: { fontFamily: interFont(400), fontSize: 11, color: 'rgba(255,255,255,.38)', marginTop: 2 },

  recentRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 13, paddingLeft: 20, paddingRight: 16 },
  recentThumb: { width: 38, height: 38, borderRadius: 11, backgroundColor: '#1c2029' },
  recentInitials: { width: 38, height: 38, borderRadius: 11, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center' },
  recentInitialsText: { fontFamily: interFont(650), fontSize: 11, color: 'rgba(255,255,255,.7)' },
  recentTitle: { fontFamily: interFont(400), fontSize: 14, color: '#fff', letterSpacing: -0.2, lineHeight: 18 },
  recentDetail: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.42)', marginTop: 4 },
  recentTime: { fontFamily: interFont(400), fontSize: 11, color: 'rgba(255,255,255,.3)' },

  settingsRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginHorizontal: 16, marginTop: 24, padding: 15, borderRadius: 18, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  settingsIconCircle: { width: 34, height: 34, borderRadius: 17, borderWidth: 1, borderColor: colors.borderStrong, alignItems: 'center', justifyContent: 'center' },
  settingsTitle: { fontFamily: interFont(620), fontSize: 14, color: '#fff', letterSpacing: -0.2 },
  settingsSubtitle: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.42)', marginTop: 3 },
});
