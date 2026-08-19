import { LinearGradient } from 'expo-linear-gradient';
import { useEffect, useRef } from 'react';
import { Animated, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Avatar } from '../components/Avatar';
import { GlassPill } from '../components/GlassPill';
import { Halo } from '../components/Halo';
import { ImageSlot } from '../components/ImageSlot';
import { LiveDot } from '../components/LiveDot';
import { ScaledCanvas } from '../components/ScaledCanvas';
import { Sheet } from '../components/Sheet';
import { SacramentoMapArt } from '../components/SacramentoMapArt';
import {
  ChevronDownIcon,
  CoupeSilhouette,
  CruiseArrowIcon,
  MessageIcon,
  PinIcon,
  SearchIcon,
  SedanSilhouette,
  SportbikeSilhouette,
} from '../components/icons';
import { colors, interFont } from '../theme';
import {
  friends,
  garage,
  meets,
  sharingOptions,
  usePullUpStore,
} from '../store';

export default function MapScreen() {
  const insets = useSafeAreaInsets();
  const sel = usePullUpStore((s) => s.sel);
  const sharingOpen = usePullUpStore((s) => s.sharingOpen);
  const sharing = usePullUpStore((s) => s.sharing);
  const going = usePullUpStore((s) => s.going);
  const driving = usePullUpStore((s) => s.driving);
  const selectMeet = usePullUpStore((s) => s.selectMeet);
  const selectFriend = usePullUpStore((s) => s.selectFriend);
  const dismiss = usePullUpStore((s) => s.dismiss);
  const toggleSharing = usePullUpStore((s) => s.toggleSharing);
  const setSharing = usePullUpStore((s) => s.setSharing);
  const cycleVehicle = usePullUpStore((s) => s.cycleVehicle);
  const togglePullUp = usePullUpStore((s) => s.togglePullUp);

  const open = sel !== null || sharingOpen;
  const meetOpen = sel === 'meetSutter' || sel === 'meetArden';
  const friendOpen = sel === 'maya' || sel === 'dre' || sel === 'kenji';
  const activeMeet = meetOpen ? meets[sel as 'meetSutter' | 'meetArden'] : null;
  const activeFriend = friendOpen ? friends[sel as 'maya' | 'dre' | 'kenji'] : null;

  const openAnim = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(openAnim, {
      toValue: open ? 1 : 0,
      duration: 400,
      useNativeDriver: true,
    }).start();
  }, [open, openAnim]);

  const mapTranslateY = openAnim.interpolate({ inputRange: [0, 1], outputRange: [0, -46] });
  const mapScale = openAnim.interpolate({ inputRange: [0, 1], outputRange: [1, 1.04] });
  const selectorOpacity = openAnim.interpolate({ inputRange: [0, 1], outputRange: [1, 0] });
  const selectorTranslateY = openAnim.interpolate({ inputRange: [0, 1], outputRange: [0, 90] });

  const sharingLabel = sharing === 'Off' ? 'Off' : `${sharing} · 2h`;

  return (
    <View style={styles.root}>
      <ScaledCanvas>
        <Animated.View
          style={[
            styles.mapArtLayer,
            { transform: [{ translateY: mapTranslateY }, { scale: mapScale }] },
          ]}
        >
          <SacramentoMapArt />
        </Animated.View>

        <LinearGradient
          pointerEvents="none"
          colors={['rgba(8,9,11,.82)', 'rgba(8,9,11,.15)', 'rgba(8,9,11,0)', 'rgba(8,9,11,.35)', 'rgba(8,9,11,.86)']}
          locations={[0, 0.24, 0.42, 0.78, 1]}
          style={StyleSheet.absoluteFill}
        />

        {/* Top bar */}
        <View style={[styles.topBar, { top: 56 }]}>
          <Text style={styles.title}>Pull Up</Text>
          <Pressable style={{ flex: 1 }} onPress={dismiss}>
            <GlassPill style={{ height: 38, borderRadius: 19, paddingHorizontal: 13, gap: 8 }}>
              <SearchIcon />
              <Text style={styles.searchPlaceholder}>Meets, friends, places</Text>
            </GlassPill>
          </Pressable>
          <Pressable onPress={toggleSharing}>
            <GlassPill style={{ height: 38, borderRadius: 19, paddingHorizontal: 12, gap: 7 }}>
              <View style={styles.sharingDot} />
              <Text style={styles.sharingLabel}>{sharingLabel}</Text>
            </GlassPill>
          </Pressable>
        </View>

        {/* Sutter Lot — live meet */}
        <Pressable
          onPress={() => selectMeet('meetSutter')}
          style={[styles.markerAnchor, { left: 196, top: 322 }]}
        >
          <View style={{ width: 58, height: 58 }}>
            <Halo color="rgba(242,160,61,.3)" borderRadius={17} />
            <View style={styles.sutterPlate}>
              <LinearGradient
                colors={['#2b2218', '#14161a']}
                start={{ x: 0.2, y: 0 }}
                end={{ x: 0.8, y: 1 }}
                style={styles.sutterPlateFill}
              >
                <Text style={styles.sutterPlateTop}>SUTTER</Text>
                <Text style={styles.sutterPlateBottom}>LOT</Text>
              </LinearGradient>
            </View>
          </View>
          <View style={styles.diamondWrap}>
            <View style={[styles.diamond, { backgroundColor: colors.amber }]} />
          </View>
          <View style={styles.markerCaptionWrap}>
            <Text style={styles.markerCaptionAmber}>LIVE · 40+</Text>
          </View>
        </Pressable>

        {/* Cars & Coffee Arden — scheduled meet */}
        <Pressable
          onPress={() => selectMeet('meetArden')}
          style={[styles.markerAnchor, { left: 318, top: 236 }]}
        >
          <View style={styles.ardenPlate}>
            <LinearGradient
              colors={['#20242a', '#14161a']}
              start={{ x: 0.2, y: 0 }}
              end={{ x: 0.8, y: 1 }}
              style={styles.sutterPlateFill}
            >
              <Text style={styles.ardenLabel}>C&amp;C</Text>
            </LinearGradient>
          </View>
          <View style={styles.diamondWrap}>
            <View style={[styles.diamond, { backgroundColor: 'rgba(255,255,255,.5)', width: 8, height: 8 }]} />
          </View>
        </Pressable>

        {/* Maya — S15 */}
        <Pressable onPress={() => selectFriend('maya')} style={[styles.markerAnchor, { left: 132, top: 452 }]}>
          <View style={[styles.friendPlate, { width: 56, height: 37, borderRadius: 12, borderColor: 'rgba(255,255,255,.72)' }]}>
            <View style={styles.silhouetteWrap}>
              <CoupeSilhouette width={48} height={20} />
            </View>
          </View>
          <View style={styles.diamondWrap}>
            <View style={[styles.diamond, { backgroundColor: '#fff', width: 9, height: 9 }]} />
          </View>
          <View style={[styles.friendLabelPill, { left: 62, top: 7 }]}>
            <Text style={styles.friendLabelText}>Maya · S15</Text>
          </View>
        </Pressable>

        {/* Dre — MT-09, rolling */}
        <Pressable onPress={() => selectFriend('dre')} style={[styles.markerAnchor, { left: 284, top: 552 }]}>
          <View style={{ width: 54, height: 36 }}>
            <Halo color="rgba(255,255,255,.13)" borderRadius={18} inset={-7} duration={2200} />
            <View style={[styles.friendPlate, { width: 54, height: 36, borderRadius: 12, borderColor: 'rgba(255,255,255,.6)' }]}>
              <View style={styles.silhouetteWrap}>
                <SportbikeSilhouette width={44} height={20} />
              </View>
            </View>
          </View>
          <View style={styles.cruiseBadge}>
            <CruiseArrowIcon size={9} />
          </View>
          <View style={styles.diamondWrap}>
            <View style={[styles.diamond, { backgroundColor: 'rgba(255,255,255,.85)', width: 8, height: 8 }]} />
          </View>
          <View style={[styles.friendLabelPill, { left: 60, top: 8 }]}>
            <Text style={styles.friendLabelText}>Dre · MT-09</Text>
          </View>
        </Pressable>

        {/* Kenji — DC2 */}
        <Pressable onPress={() => selectFriend('kenji')} style={[styles.markerAnchor, { left: 96, top: 640 }]}>
          <View style={[styles.friendPlate, { width: 50, height: 34, borderRadius: 11, borderColor: 'rgba(255,255,255,.45)' }]}>
            <View style={styles.silhouetteWrap}>
              <SedanSilhouette width={44} height={19} color="rgba(255,255,255,.8)" />
            </View>
          </View>
          <View style={styles.diamondWrap}>
            <View style={[styles.diamond, { backgroundColor: 'rgba(255,255,255,.6)', width: 8, height: 8 }]} />
          </View>
        </Pressable>

        {/* You */}
        <View pointerEvents="none" style={[styles.markerAnchor, { left: 212, top: 706, transform: [{ translateX: -7 }, { translateY: -7 }] }]}>
          <View style={{ width: 14, height: 14 }}>
            <Halo color="rgba(255,255,255,.07)" borderRadius={999} inset={-16} duration={3000} />
            <View style={styles.youDot} />
          </View>
        </View>

        {/* Vehicle selector */}
        <Animated.View
          pointerEvents={open ? 'none' : 'auto'}
          style={[
            styles.selectorWrap,
            {
              opacity: selectorOpacity,
              transform: [{ translateY: selectorTranslateY }],
              bottom: 104,
            },
          ]}
        >
          <Pressable onPress={cycleVehicle}>
            <GlassPill style={{ height: 44, borderRadius: 22, paddingRight: 14, paddingLeft: 4, gap: 9 }} intensity={50}>
              <Avatar size={36} label={garage[driving].badge} fontSize={11.5} />
              <View>
                <Text style={styles.selectorEyebrow}>DRIVING</Text>
                <Text style={styles.selectorVehicle} numberOfLines={1}>
                  {garage[driving].name}
                </Text>
              </View>
              <ChevronDownIcon />
            </GlassPill>
          </Pressable>
        </Animated.View>
      </ScaledCanvas>

      {/* Meet sheet */}
      <Sheet visible={meetOpen} onDismiss={dismiss} style={{ paddingBottom: insets.bottom + 26 }}>
        {activeMeet ? (
          <>
            <View style={{ height: 150 }}>
              <ImageSlot placeholder="Meet cover photo" />
              <LinearGradient
                pointerEvents="none"
                colors={['rgba(16,18,22,.35)', 'rgba(16,18,22,0)', 'rgba(16,18,22,.9)']}
                locations={[0, 0.4, 1]}
                style={StyleSheet.absoluteFill}
              />
              <View style={styles.sheetHandle} />
              {activeMeet.live ? (
                <View style={styles.liveNowPill}>
                  <LiveDot />
                  <Text style={styles.liveNowText}>LIVE NOW</Text>
                </View>
              ) : null}
            </View>
            <View style={{ paddingHorizontal: 20, paddingTop: 14 }}>
              <Text style={styles.meetTitle}>{activeMeet.title}</Text>
              <Text style={styles.meetVenue}>{activeMeet.venue}</Text>
              <View style={styles.meetMetaRow}>
                <Text style={styles.meetMetaText}>{activeMeet.distance}</Text>
                <Text style={styles.meetMetaDot}>·</Text>
                <Text style={styles.meetMetaText}>{activeMeet.timing}</Text>
                <Text style={styles.meetMetaDot}>·</Text>
                <Text style={[styles.meetMetaText, activeMeet.live && { color: colors.amber }]}>
                  {activeMeet.turnout}
                </Text>
              </View>
            </View>
            <View style={styles.attendeesRow}>
              <View style={{ flexDirection: 'row' }}>
                <Avatar size={30} label="M" border="#101216" borderWidth={2} />
                <Avatar size={30} label="K" border="#101216" borderWidth={2} style={{ marginLeft: -9 }} />
                <Avatar size={30} label="R" border="#101216" borderWidth={2} style={{ marginLeft: -9 }} />
              </View>
              <Text style={styles.attendeesText}>{activeMeet.friendsHere}</Text>
            </View>
            <View style={styles.hostRow}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 9 }}>
                <Avatar size={26} radius={8} label={activeMeet.hostInitials} fontSize={10} />
                <View>
                  <Text style={styles.hostEyebrow}>HOSTED BY</Text>
                  <Text style={styles.hostName}>{activeMeet.hostName}</Text>
                </View>
              </View>
              {activeMeet.verified ? <Text style={styles.verifiedBadge}>VERIFIED HOST</Text> : null}
            </View>
            <View style={styles.sheetActionsRow}>
              <Pressable onPress={togglePullUp} style={[styles.pullUpButton, { backgroundColor: going ? 'rgba(255,255,255,.08)' : '#fff' }]}>
                <Text style={[styles.pullUpButtonText, { color: going ? colors.amber : '#0b0c0e' }]}>
                  {going ? "You're pulling up" : 'Pull up'}
                </Text>
              </Pressable>
              <Pressable style={styles.iconCircleButton}>
                <PinIcon size={19} />
              </Pressable>
            </View>
          </>
        ) : null}
      </Sheet>

      {/* Friend sheet */}
      <Sheet visible={friendOpen} onDismiss={dismiss} style={{ paddingHorizontal: 20, paddingTop: 12, paddingBottom: insets.bottom + 26 }}>
        {activeFriend ? (
          <>
            <View style={styles.sheetHandleStatic} />
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
              <Avatar size={52} radius={26} label={activeFriend.name.charAt(0)} fontSize={18} border="rgba(255,255,255,.12)" />
              <View style={{ flex: 1 }}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Text style={styles.friendName}>{activeFriend.name}</Text>
                  <Text style={styles.friendCrewBadge}>{activeFriend.crew}</Text>
                </View>
                <Text style={styles.friendStatus}>{activeFriend.status}</Text>
              </View>
            </View>
            <View style={styles.friendVehicleCard}>
              <View style={{ height: 112 }}>
                <ImageSlot placeholder="Current vehicle photo" />
              </View>
              <View style={styles.friendVehicleRow}>
                <View>
                  <Text style={styles.hostEyebrow}>CURRENTLY IN</Text>
                  <Text style={styles.friendVehicleName}>{activeFriend.vehicle}</Text>
                </View>
                <Text style={styles.friendVehicleMeta}>{activeFriend.vehicleMeta}</Text>
              </View>
            </View>
            <View style={styles.friendActionsRow}>
              <View style={styles.pullUpToThemButton}>
                <Text style={styles.pullUpToThemText}>Pull up to them</Text>
              </View>
              <Pressable style={styles.iconCircleButtonBordered}>
                <MessageIcon />
              </Pressable>
            </View>
          </>
        ) : null}
      </Sheet>

      {/* Sharing sheet */}
      <Sheet visible={sharingOpen} onDismiss={dismiss} style={{ paddingHorizontal: 20, paddingTop: 12, paddingBottom: insets.bottom + 26 }}>
        <View style={styles.sheetHandleStatic} />
        <Text style={styles.sharingTitle}>Who can see you</Text>
        <Text style={styles.sharingSubtitle}>Ends automatically. Nothing stays on by default.</Text>
        <View style={{ gap: 8, marginTop: 16 }}>
          {sharingOptions.map((opt) => (
            <Pressable key={opt.label} onPress={() => setSharing(opt.label)} style={styles.sharingOptionRow}>
              <View style={[styles.sharingOptionDot, { backgroundColor: opt.label === sharing ? '#e8e8ea' : 'rgba(255,255,255,.2)' }]} />
              <View style={{ flex: 1 }}>
                <Text style={styles.sharingOptionLabel}>{opt.label}</Text>
                <Text style={styles.sharingOptionNote}>{opt.note}</Text>
              </View>
              {opt.label === sharing ? <Text style={styles.sharingOptionState}>ON</Text> : null}
            </Pressable>
          ))}
        </View>
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.screenBg },
  mapArtLayer: { position: 'absolute', top: -60, left: -60, right: -60, bottom: -60 },
  topBar: { position: 'absolute', left: 0, right: 0, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 16 },
  title: { fontFamily: interFont(700), fontSize: 15, color: '#fff', letterSpacing: -0.3, paddingRight: 2 },
  searchPlaceholder: { fontFamily: interFont(400), fontSize: 13.5, color: 'rgba(255,255,255,.45)', letterSpacing: -0.1 },
  sharingDot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#e8e8ea' },
  sharingLabel: { fontFamily: interFont(550), fontSize: 12.5, color: '#e8e8ea', letterSpacing: -0.1 },

  markerAnchor: { position: 'absolute' },
  diamondWrap: { alignItems: 'center', marginTop: -3 },
  diamond: { width: 10, height: 10, borderRadius: 2, transform: [{ rotate: '45deg' }] },
  markerCaptionWrap: { alignItems: 'center', marginTop: 3 },
  markerCaptionAmber: { fontFamily: interFont(650), fontSize: 10.5, letterSpacing: 0.6, color: colors.amber },

  sutterPlate: { width: 58, height: 58, borderRadius: 17, overflow: 'hidden', borderWidth: 2, borderColor: colors.amber, ...shadow(24) },
  sutterPlateFill: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 1 },
  sutterPlateTop: { fontFamily: interFont(650), fontSize: 9, letterSpacing: 0.9, color: colors.amber },
  sutterPlateBottom: { fontFamily: interFont(600), fontSize: 8.5, letterSpacing: 0.6, color: 'rgba(255,255,255,.42)' },

  ardenPlate: { width: 44, height: 44, borderRadius: 14, overflow: 'hidden', borderWidth: 1.5, borderColor: 'rgba(255,255,255,.34)', ...shadow(18) },
  ardenLabel: { fontFamily: interFont(650), fontSize: 8.5, letterSpacing: 0.7, color: 'rgba(255,255,255,.6)' },

  friendPlate: { overflow: 'hidden', backgroundColor: 'rgba(13,15,18,.88)', borderWidth: 1.5, ...shadow(22) },
  silhouetteWrap: { flex: 1, alignItems: 'center', justifyContent: 'flex-end', paddingBottom: 6 },
  friendLabelPill: {
    position: 'absolute',
    height: 24,
    paddingHorizontal: 10,
    borderRadius: 12,
    backgroundColor: 'rgba(12,13,15,.82)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,.12)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  friendLabelText: { fontFamily: interFont(600), fontSize: 11, color: '#fff', letterSpacing: -0.1 },
  cruiseBadge: {
    position: 'absolute',
    left: 44,
    top: -7,
    width: 18,
    height: 18,
    borderRadius: 9,
    backgroundColor: '#0b0c0e',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,.2)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  youDot: { width: 14, height: 14, borderRadius: 7, backgroundColor: '#fff', borderWidth: 2.5, borderColor: '#0b0c0e' },

  selectorWrap: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  selectorEyebrow: { fontFamily: interFont(600), fontSize: 9.5, letterSpacing: 1, color: 'rgba(255,255,255,.4)' },
  selectorVehicle: { fontFamily: interFont(600), fontSize: 12.5, color: '#fff', letterSpacing: -0.1, maxWidth: 150 },

  sheetHandle: { position: 'absolute', top: 10, left: '50%', marginLeft: -19, width: 38, height: 4, borderRadius: 2, backgroundColor: 'rgba(255,255,255,.45)' },
  sheetHandleStatic: { width: 38, height: 4, borderRadius: 2, backgroundColor: 'rgba(255,255,255,.18)', alignSelf: 'center', marginBottom: 16 },
  liveNowPill: { position: 'absolute', top: 16, right: 14, flexDirection: 'row', alignItems: 'center', gap: 6, height: 26, paddingHorizontal: 10, borderRadius: 13, backgroundColor: 'rgba(11,12,14,.6)' },
  liveNowText: { fontFamily: interFont(650), fontSize: 10.5, letterSpacing: 0.7, color: colors.amber },
  meetTitle: { fontFamily: interFont(680), fontSize: 24, color: '#fff', letterSpacing: -0.6, lineHeight: 27 },
  meetVenue: { fontFamily: interFont(550), fontSize: 13.5, color: 'rgba(255,255,255,.66)', marginTop: 4, letterSpacing: -0.1 },
  meetMetaRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 8 },
  meetMetaText: { fontFamily: interFont(400), fontSize: 13, color: 'rgba(255,255,255,.5)', letterSpacing: -0.1 },
  meetMetaDot: { fontSize: 13, color: 'rgba(255,255,255,.2)' },
  attendeesRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 20, paddingTop: 16 },
  attendeesText: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.6)', letterSpacing: -0.1 },
  hostRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 14 },
  hostEyebrow: { fontFamily: interFont(600), fontSize: 9.5, letterSpacing: 0.9, color: 'rgba(255,255,255,.35)' },
  hostName: { fontFamily: interFont(550), fontSize: 12.5, color: '#fff' },
  verifiedBadge: { fontFamily: interFont(600), fontSize: 10.5, letterSpacing: 0.5, color: 'rgba(255,255,255,.5)', borderWidth: 1, borderColor: 'rgba(255,255,255,.14)', borderRadius: 11, paddingHorizontal: 9, paddingVertical: 4 },
  sheetActionsRow: { flexDirection: 'row', gap: 10, paddingHorizontal: 20, paddingTop: 18 },
  pullUpButton: { flex: 1, height: 50, borderRadius: 25, alignItems: 'center', justifyContent: 'center' },
  pullUpButtonText: { fontFamily: interFont(650), fontSize: 15.5, letterSpacing: -0.2 },
  iconCircleButton: { width: 50, height: 50, borderRadius: 25, borderWidth: 1, borderColor: 'rgba(255,255,255,.14)', alignItems: 'center', justifyContent: 'center' },

  friendName: { fontFamily: interFont(660), fontSize: 19, color: '#fff', letterSpacing: -0.4 },
  friendCrewBadge: { fontFamily: interFont(600), fontSize: 10, letterSpacing: 0.6, color: 'rgba(255,255,255,.5)', borderWidth: 1, borderColor: 'rgba(255,255,255,.14)', borderRadius: 10, paddingHorizontal: 7, paddingVertical: 3 },
  friendStatus: { fontFamily: interFont(400), fontSize: 13, color: 'rgba(255,255,255,.55)', marginTop: 3, letterSpacing: -0.1 },
  friendVehicleCard: { marginTop: 16, borderRadius: 18, overflow: 'hidden', backgroundColor: colors.surfaceRaised, borderWidth: 1, borderColor: colors.border },
  friendVehicleRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: 15 },
  friendVehicleName: { fontFamily: interFont(600), fontSize: 14.5, color: '#fff', letterSpacing: -0.2 },
  friendVehicleMeta: { fontFamily: interFont(400), fontSize: 12, color: 'rgba(255,255,255,.4)' },
  friendActionsRow: { flexDirection: 'row', gap: 9, marginTop: 16 },
  pullUpToThemButton: { flex: 1, height: 46, borderRadius: 23, backgroundColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  pullUpToThemText: { fontFamily: interFont(650), fontSize: 14.5, color: '#0b0c0e', letterSpacing: -0.2 },
  iconCircleButtonBordered: { width: 46, height: 46, borderRadius: 23, borderWidth: 1, borderColor: 'rgba(255,255,255,.14)', alignItems: 'center', justifyContent: 'center' },

  sharingTitle: { fontFamily: interFont(660), fontSize: 18, color: '#fff', letterSpacing: -0.4 },
  sharingSubtitle: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.45)', marginTop: 4, letterSpacing: -0.1 },
  sharingOptionRow: { flexDirection: 'row', alignItems: 'center', gap: 12, padding: 15, borderRadius: 16, backgroundColor: colors.surfaceRaised, borderWidth: 1, borderColor: colors.border },
  sharingOptionDot: { width: 8, height: 8, borderRadius: 4 },
  sharingOptionLabel: { fontFamily: interFont(600), fontSize: 14, color: '#fff', letterSpacing: -0.1 },
  sharingOptionNote: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.42)', marginTop: 2 },
  sharingOptionState: { fontFamily: interFont(600), fontSize: 11, letterSpacing: 0.4, color: '#e8e8ea' },
});

function shadow(radius: number) {
  return {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: radius / 3 },
    shadowOpacity: 0.55,
    shadowRadius: radius,
    elevation: 8,
  } as const;
}
