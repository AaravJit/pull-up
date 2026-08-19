import { LinearGradient } from 'expo-linear-gradient';
import { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Avatar } from '../components/Avatar';
import { ImageSlot } from '../components/ImageSlot';
import { LiveDot } from '../components/LiveDot';
import { ChevronRightIcon, PlusIcon, SearchIcon } from '../components/icons';
import { colors, interFont } from '../theme';

const CHIPS = ['Tonight', 'Live', 'Cars', 'Bikes', 'Cruises', 'Shows'];

// Whether there's live automotive activity worth surfacing right now — the
// design covers both states; this mock always has Sac Nights live.
const HAS_LIVE_MEETS = true;

export default function MeetsScreen() {
  const insets = useSafeAreaInsets();
  const [chip, setChip] = useState('Tonight');

  return (
    <View style={styles.root}>
      <ScrollView
        contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 130 }}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <Text style={styles.headerTitle}>Meets</Text>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <Pressable style={styles.iconButton}>
              <SearchIcon size={14} color="rgba(255,255,255,.75)" strokeWidth={1.7} />
            </Pressable>
            <Pressable style={styles.hostPill}>
              <PlusIcon size={13} strokeWidth={2.1} />
              <Text style={styles.hostPillText}>Host</Text>
            </Pressable>
          </View>
        </View>

        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chipsRow}>
          {CHIPS.map((c) => {
            const active = c === chip;
            return (
              <Pressable
                key={c}
                onPress={() => setChip(c)}
                style={[styles.chip, { backgroundColor: active ? '#fff' : 'transparent', borderColor: active ? '#fff' : 'rgba(255,255,255,.13)' }]}
              >
                <Text style={[styles.chipText, { color: active ? '#0b0c0e' : 'rgba(255,255,255,.7)' }]}>{c}</Text>
              </Pressable>
            );
          })}
        </ScrollView>

        {HAS_LIVE_MEETS ? (
          <>
            <View style={styles.sectionLiveRow}>
              <LiveDot />
              <Text style={styles.sectionLiveLabel}>LIVE NOW</Text>
              <Text style={styles.sectionCountLabel}>2 NEARBY</Text>
            </View>

            <View style={styles.liveCard}>
              <View style={{ height: 186 }}>
                <ImageSlot placeholder="Sac Nights cover" />
                <LinearGradient
                  pointerEvents="none"
                  colors={['rgba(11,12,14,.5)', 'rgba(11,12,14,0)', 'rgba(11,12,14,.92)']}
                  locations={[0, 0.36, 1]}
                  style={StyleSheet.absoluteFill}
                />
                <View style={styles.liveNowPill}>
                  <LiveDot />
                  <Text style={styles.liveNowText}>LIVE NOW</Text>
                </View>
                <View style={styles.verifiedPill}>
                  <Text style={styles.verifiedPillText}>VERIFIED HOST</Text>
                </View>
                <View style={styles.liveCardOverlay} pointerEvents="none">
                  <Text style={styles.liveCardTitle}>Sac Nights</Text>
                  <Text style={styles.liveCardVenue}>Sutter Lot · Midtown</Text>
                </View>
              </View>
              <View style={styles.liveCardMetaRow}>
                <Text style={styles.liveCardMetaText}>0.8 mi</Text>
                <Text style={styles.metaDot}>·</Text>
                <Text style={[styles.liveCardMetaText, { color: colors.amber }]}>~40 here</Text>
                <Text style={styles.metaDot}>·</Text>
                <Text style={styles.liveCardMetaText}>1h 20m in</Text>
              </View>
              <View style={styles.attendeesRow}>
                <View style={{ flexDirection: 'row' }}>
                  <Avatar size={26} label="M" border="#101216" borderWidth={2} />
                  <Avatar size={26} label="K" border="#101216" borderWidth={2} style={{ marginLeft: -8 }} />
                  <Avatar size={26} label="R" border="#101216" borderWidth={2} style={{ marginLeft: -8 }} />
                </View>
                <Text style={styles.attendeesText}>Maya, Kenji +1 are here</Text>
              </View>
            </View>

            <DetectedActivityCard location="65th & Folsom · 3.1 mi" count="~18 vehicles" note="Activity rising" />

            <Text style={styles.sectionLabel}>HAPPENING SOON</Text>
            <SoonCard tag="CRUISE" title="Taco Run Cruise" time="10:30 PM" location="Meets at Southside Park · 2.4 mi" chips={['Cruise', '3 friends going']} />
            <SoonCard tag="BIKES" title="Elk Grove Bike Night" time="9:45 PM" location="Laguna Town Hall · 6.1 mi · 40 RSVPs" chips={['Bike-heavy']} />

            <Text style={styles.sectionLabel}>UPCOMING</Text>
            <Text style={styles.dayLabel}>Saturday</Text>
            <UpcomingRow time="7:30" ampm="AM" title="Cars & Coffee Arden" detail="4.2 mi · Good match for your BMW" />
            <UpcomingRow time="10:00" ampm="AM" title="Rocklin Show & Shine" detail="21 mi · Show · 2 friends going" />
            <Text style={[styles.dayLabel, { paddingTop: 20 }]}>Sunday</Text>
            <UpcomingRow time="8:00" ampm="AM" title="Delta Backroads Cruise" detail="Rio Vista loop · 12 riders" />
          </>
        ) : (
          <>
            <View style={{ paddingHorizontal: 20, paddingTop: 26 }}>
              <Text style={styles.quietTitle}>Quiet out there right now</Text>
              <Text style={styles.quietSubtitle}>Nothing live within 15 miles. Here's what's building.</Text>
            </View>

            <DetectedActivityCard location="Roseville · 22 mi" count="~9 vehicles" note="Slow build" />

            <Text style={styles.sectionLabel}>FRIENDS ARE GOING</Text>
            <View style={styles.soonCard}>
              <View style={styles.soonTile}>
                <Text style={styles.soonTileText}>CARS</Text>
              </View>
              <View style={{ flex: 1, minWidth: 0 }}>
                <View style={styles.soonHeaderRow}>
                  <Text style={styles.soonTitle}>Cars &amp; Coffee Arden</Text>
                  <Text style={styles.soonTime}>Sat 7:30</Text>
                </View>
                <Text style={styles.soonLocation}>Arden Fair lot · 4.2 mi</Text>
                <View style={styles.friendsGoingRow}>
                  <View style={{ flexDirection: 'row' }}>
                    <Avatar size={22} label="M" fontSize={9} border="#101216" borderWidth={2} />
                    <Avatar size={22} label="D" fontSize={9} border="#101216" borderWidth={2} style={{ marginLeft: -7 }} />
                    <Avatar size={22} label="K" fontSize={9} border="#101216" borderWidth={2} style={{ marginLeft: -7 }} />
                  </View>
                  <Text style={styles.friendsGoingText}>3 friends going · good match for your BMW</Text>
                </View>
              </View>
            </View>

            <Text style={styles.sectionLabel}>SAVED</Text>
            <View style={styles.upcomingRow}>
              <View style={styles.upcomingTimeCol}>
                <Text style={styles.upcomingTime}>Aug</Text>
                <Text style={styles.upcomingAmpm}>30</Text>
              </View>
              <View style={{ flex: 1, minWidth: 0 }}>
                <Text style={styles.upcomingTitle}>Nights at the Speedway</Text>
                <Text style={styles.upcomingDetail}>All Star Bowl · saved 2 weeks ago</Text>
              </View>
              <ChevronRightIcon />
            </View>

            <View style={styles.hostInlineCard}>
              <Text style={styles.hostInlineTitle}>Somebody has to start it</Text>
              <Text style={styles.hostInlineSubtitle}>Pick a lot, pick a time. Your crew gets it first.</Text>
              <View style={styles.hostInlineButton}>
                <PlusIcon size={14} color="#0b0c0e" strokeWidth={2.2} />
                <Text style={styles.hostInlineButtonText}>Host a meet</Text>
              </View>
            </View>
          </>
        )}
      </ScrollView>
    </View>
  );
}

function DetectedActivityCard({ location, count, note }: { location: string; count: string; note: string }) {
  return (
    <View style={styles.detectedCard}>
      <View style={styles.detectedRow}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 9 }}>
          <View style={styles.detectedDotRing}>
            <View style={styles.detectedDot} />
          </View>
          <View>
            <Text style={styles.detectedTitle}>Automotive activity</Text>
            <Text style={styles.detectedLocation}>{location}</Text>
          </View>
        </View>
        <View style={{ alignItems: 'flex-end' }}>
          <Text style={styles.detectedCount}>{count}</Text>
          <Text style={styles.detectedNote}>{note}</Text>
        </View>
      </View>
      <Text style={styles.detectedFootnote}>Not a hosted meet · no attendee list</Text>
    </View>
  );
}

function SoonCard({ tag, title, time, location, chips }: { tag: string; title: string; time: string; location: string; chips: string[] }) {
  return (
    <View style={styles.soonCard}>
      <View style={styles.soonTile}>
        <Text style={styles.soonTileText}>{tag}</Text>
      </View>
      <View style={{ flex: 1, minWidth: 0 }}>
        <View style={styles.soonHeaderRow}>
          <Text style={styles.soonTitle}>{title}</Text>
          <Text style={styles.soonTime}>{time}</Text>
        </View>
        <Text style={styles.soonLocation}>{location}</Text>
        <View style={styles.soonChipsRow}>
          {chips.map((c) => (
            <Text key={c} style={styles.soonChip}>
              {c}
            </Text>
          ))}
        </View>
      </View>
    </View>
  );
}

function UpcomingRow({ time, ampm, title, detail }: { time: string; ampm: string; title: string; detail: string }) {
  return (
    <View style={styles.upcomingRow}>
      <View style={styles.upcomingTimeCol}>
        <Text style={styles.upcomingTime}>{time}</Text>
        <Text style={styles.upcomingAmpm}>{ampm}</Text>
      </View>
      <View style={{ flex: 1, minWidth: 0 }}>
        <Text style={styles.upcomingTitle}>{title}</Text>
        <Text style={styles.upcomingDetail}>{detail}</Text>
      </View>
      <ChevronRightIcon />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.screenBg },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 8 },
  headerTitle: { fontFamily: interFont(700), fontSize: 30, color: '#fff', letterSpacing: -0.9 },
  iconButton: { width: 34, height: 34, borderRadius: 17, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center' },
  hostPill: { height: 34, flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 13, borderRadius: 17, borderWidth: 1, borderColor: colors.borderStrong },
  hostPillText: { fontFamily: interFont(600), fontSize: 12.5, color: '#fff', letterSpacing: -0.1 },

  chipsRow: { gap: 7, paddingHorizontal: 20, paddingTop: 16 },
  chip: { height: 30, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 12, borderRadius: 15, borderWidth: 1 },
  chipText: { fontFamily: interFont(600), fontSize: 12.5, letterSpacing: -0.1 },

  sectionLiveRow: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 20, paddingTop: 24 },
  sectionLiveLabel: { fontFamily: interFont(650), fontSize: 11, letterSpacing: 1.1, color: colors.amber },
  sectionCountLabel: { fontFamily: interFont(600), fontSize: 11, letterSpacing: 0.4, color: 'rgba(255,255,255,.32)' },

  liveCard: { marginHorizontal: 16, marginTop: 12, borderRadius: 22, overflow: 'hidden', backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  liveNowPill: { position: 'absolute', top: 13, left: 14, flexDirection: 'row', alignItems: 'center', gap: 7, height: 26, paddingHorizontal: 11, borderRadius: 13, backgroundColor: 'rgba(11,12,14,.62)' },
  liveNowText: { fontFamily: interFont(650), fontSize: 10, letterSpacing: 0.8, color: colors.amber },
  verifiedPill: { position: 'absolute', top: 13, right: 14, height: 26, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 10, borderRadius: 13, backgroundColor: 'rgba(11,12,14,.55)' },
  verifiedPillText: { fontFamily: interFont(600), fontSize: 10, letterSpacing: 0.6, color: 'rgba(255,255,255,.7)' },
  liveCardOverlay: { position: 'absolute', left: 16, right: 16, bottom: 14 },
  liveCardTitle: { fontFamily: interFont(680), fontSize: 22, color: '#fff', letterSpacing: -0.55, lineHeight: 25 },
  liveCardVenue: { fontFamily: interFont(550), fontSize: 13, color: 'rgba(255,255,255,.62)', marginTop: 4, letterSpacing: -0.1 },
  liveCardMetaRow: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 16, paddingTop: 13 },
  liveCardMetaText: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.5)', letterSpacing: -0.1 },
  metaDot: { color: 'rgba(255,255,255,.4)' },
  attendeesRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 16, paddingTop: 12, paddingBottom: 16 },
  attendeesText: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.6)', letterSpacing: -0.1 },

  detectedCard: { marginHorizontal: 16, marginTop: 10, borderRadius: 18, backgroundColor: 'rgba(255,255,255,.035)', borderWidth: 1, borderStyle: 'dashed', borderColor: 'rgba(255,255,255,.14)', padding: 15 },
  detectedRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  detectedDotRing: { width: 26, height: 26, borderRadius: 13, borderWidth: 1, borderColor: 'rgba(255,255,255,.14)', alignItems: 'center', justifyContent: 'center' },
  detectedDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: 'rgba(255,255,255,.45)' },
  detectedTitle: { fontFamily: interFont(620), fontSize: 14, color: 'rgba(255,255,255,.86)', letterSpacing: -0.2 },
  detectedLocation: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.4)', marginTop: 3 },
  detectedCount: { fontFamily: interFont(600), fontSize: 12.5, color: 'rgba(255,255,255,.7)' },
  detectedNote: { fontFamily: interFont(400), fontSize: 11, color: 'rgba(255,255,255,.35)', marginTop: 3 },
  detectedFootnote: { fontFamily: interFont(400), fontSize: 10.5, color: 'rgba(255,255,255,.28)', marginTop: 11, letterSpacing: 0.2 },

  sectionLabel: { fontFamily: interFont(650), fontSize: 11, letterSpacing: 1.1, color: 'rgba(255,255,255,.34)', paddingHorizontal: 20, paddingTop: 26 },

  soonCard: { flexDirection: 'row', gap: 12, marginHorizontal: 16, marginTop: 12, padding: 12, borderRadius: 18, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border },
  soonTile: { width: 78, height: 78, borderRadius: 13, overflow: 'hidden', alignItems: 'flex-start', justifyContent: 'flex-end', padding: 8, backgroundColor: '#1c2029' },
  soonTileText: { fontFamily: interFont(650), fontSize: 9, letterSpacing: 0.8, color: 'rgba(255,255,255,.4)' },
  soonHeaderRow: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 },
  soonTitle: { fontFamily: interFont(640), fontSize: 15.5, color: '#fff', letterSpacing: -0.3, flexShrink: 1 },
  soonTime: { fontFamily: interFont(600), fontSize: 12, color: 'rgba(255,255,255,.55)' },
  soonLocation: { fontFamily: interFont(400), fontSize: 12, color: 'rgba(255,255,255,.45)', marginTop: 4, letterSpacing: -0.05 },
  soonChipsRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 9 },
  soonChip: { fontFamily: interFont(600), fontSize: 11, color: 'rgba(255,255,255,.8)', backgroundColor: 'rgba(255,255,255,.07)', borderRadius: 10, paddingHorizontal: 9, paddingVertical: 4 },

  dayLabel: { fontFamily: interFont(640), fontSize: 13, color: 'rgba(255,255,255,.85)', paddingHorizontal: 20, paddingTop: 14, letterSpacing: -0.2 },
  upcomingRow: { flexDirection: 'row', alignItems: 'center', gap: 13, marginHorizontal: 16, marginTop: 10, paddingHorizontal: 14, paddingVertical: 11, borderRadius: 16, backgroundColor: 'rgba(255,255,255,.04)' },
  upcomingTimeCol: { width: 44, alignItems: 'center' },
  upcomingTime: { fontFamily: interFont(670), fontSize: 15, color: '#fff', letterSpacing: -0.3 },
  upcomingAmpm: { fontFamily: interFont(600), fontSize: 9.5, color: 'rgba(255,255,255,.35)', letterSpacing: 0.6 },
  upcomingTitle: { fontFamily: interFont(620), fontSize: 14.5, color: '#fff', letterSpacing: -0.25 },
  upcomingDetail: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.42)', marginTop: 3 },

  quietTitle: { fontFamily: interFont(660), fontSize: 17, color: '#fff', letterSpacing: -0.4 },
  quietSubtitle: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.45)', marginTop: 5, letterSpacing: -0.1 },

  friendsGoingRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 10 },
  friendsGoingText: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.55)' },

  hostInlineCard: { marginHorizontal: 16, marginTop: 26, borderRadius: 20, overflow: 'hidden', backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, padding: 18 },
  hostInlineTitle: { fontFamily: interFont(660), fontSize: 16.5, color: '#fff', letterSpacing: -0.35 },
  hostInlineSubtitle: { fontFamily: interFont(400), fontSize: 12.5, color: 'rgba(255,255,255,.45)', marginTop: 5, letterSpacing: -0.1 },
  hostInlineButton: { flexDirection: 'row', alignItems: 'center', gap: 7, alignSelf: 'flex-start', height: 38, paddingHorizontal: 16, borderRadius: 19, backgroundColor: '#fff', marginTop: 15 },
  hostInlineButtonText: { fontFamily: interFont(650), fontSize: 13.5, color: '#0b0c0e', letterSpacing: -0.2 },
});
