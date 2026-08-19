import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Avatar } from '../components/Avatar';
import { LiveDot } from '../components/LiveDot';
import { colors, interFont } from '../theme';
import { usePullUpStore } from '../store';

export default function ActivityScreen() {
  const insets = useSafeAreaInsets();
  const unread = usePullUpStore((s) => s.unread);
  const markActivityRead = usePullUpStore((s) => s.markActivityRead);
  const hasUnread = unread > 0;

  return (
    <View style={styles.root}>
      <ScrollView
        contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 130 }}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <Text style={styles.headerTitle}>Activity</Text>
          {hasUnread ? (
            <Pressable onPress={markActivityRead} style={styles.markReadPill}>
              <Text style={styles.markReadText}>Mark read</Text>
            </Pressable>
          ) : null}
        </View>

        <View style={styles.sectionLabelRow}>
          <Text style={styles.sectionLabel}>NEW</Text>
          {hasUnread ? <Text style={styles.unreadCountLabel}>{unread} UPDATES</Text> : null}
        </View>

        <View style={{ marginTop: 8 }}>
          <Row unread={hasUnread} onPress={markActivityRead} thumbnail>
            <Avatar size={38} label="M" fontSize={14} />
            <View style={styles.rowBody}>
              <RichLine bold="Maya" text=" pulled up to " boldEnd="Sac Nights" />
              <View style={styles.subRow}>
                <Text style={styles.subText}>S15 · Sutter Lot</Text>
                <View style={styles.liveInline}>
                  <LiveDot size={5} />
                  <Text style={styles.liveInlineText}>LIVE</Text>
                </View>
              </View>
            </View>
            <Text style={styles.time}>12m</Text>
          </Row>

          <Row unread={hasUnread} onPress={markActivityRead}>
            <View style={styles.liveIconTile}>
              <LiveDot size={7} />
            </View>
            <View style={styles.rowBody}>
              <RichLine bold="Sac Nights" text=" is live now" />
              <Text style={styles.subText}>Saved meet · 0.8 mi · ~40 here</Text>
            </View>
            <Text style={styles.time}>20m</Text>
          </Row>

          <Row unread={hasUnread} onPress={markActivityRead} thumbnail>
            <Avatar size={38} label="D" fontSize={14} />
            <View style={styles.rowBody}>
              <RichLine bold="Dre" text=" started a cruise" />
              <View style={styles.subRow}>
                <Text style={styles.subText}>MT-09 · Delta Backroads</Text>
                <View style={styles.liveInline}>
                  <LiveDot size={5} />
                  <Text style={styles.liveInlineText}>ROLLING</Text>
                </View>
              </View>
            </View>
            <Text style={styles.time}>35m</Text>
          </Row>
        </View>

        <Text style={styles.sectionLabel}>EARLIER TODAY</Text>
        <View style={{ marginTop: 8 }}>
          <Row thumbnail>
            <Avatar size={38} label="K" fontSize={14} />
            <View style={styles.rowBody}>
              <RichLine bold="Kenji" text=" added coilovers to the Integra build" />
              <Text style={styles.subText}>Fortune Auto 500s · DC2 · 82k mi</Text>
            </View>
            <Text style={styles.time}>3h</Text>
          </Row>
          <Row thumbnail>
            <Avatar size={38} radius={11} label="GC" fontSize={12} />
            <View style={styles.rowBody}>
              <RichLine bold="Gearbox Collective" text=" posted a new meet" />
              <Text style={styles.subText}>Rocklin Show &amp; Shine · Sat 10:00 AM</Text>
            </View>
            <Text style={styles.time}>5h</Text>
          </Row>
          <Row>
            <View style={{ flexDirection: 'row', width: 44 }}>
              <Avatar size={26} label="M" fontSize={10} border="#0b0c0e" borderWidth={2} />
              <Avatar size={26} label="R" fontSize={10} border="#0b0c0e" borderWidth={2} style={{ marginLeft: -8 }} />
            </View>
            <View style={styles.rowBody}>
              <RichLine bold="3 friends" text=" are pulling up to Cars &amp; Coffee" />
              <Text style={styles.subText}>Saturday 7:30 AM · Arden Fair lot</Text>
            </View>
            <Text style={styles.time}>6h</Text>
          </Row>
        </View>

        <Text style={styles.sectionLabel}>YESTERDAY</Text>
        <View style={{ marginTop: 8 }}>
          <Row thumbnail>
            <Avatar size={38} label="R" fontSize={14} />
            <View style={styles.rowBody}>
              <RichLine bold="Rey" text=" is driving the E36 now" />
              <Text style={styles.subText}>1996 BMW 328i · was the Silvia</Text>
            </View>
            <Text style={styles.time}>1d</Text>
          </Row>
          <Row>
            <View style={styles.borderedInitials}>
              <Text style={styles.borderedInitialsText}>NS</Text>
            </View>
            <View style={styles.rowBody}>
              <RichLine bold="Tess" text=" joined Night Shift" />
              <Text style={styles.subText}>Your crew · 9 members</Text>
            </View>
            <Text style={styles.time}>1d</Text>
          </Row>
        </View>
      </ScrollView>
    </View>
  );
}

function Row({
  children,
  unread,
  thumbnail,
  onPress,
}: {
  children: React.ReactNode;
  unread?: boolean;
  thumbnail?: boolean;
  onPress?: () => void;
}) {
  return (
    <Pressable onPress={onPress} style={[styles.row, unread && styles.rowUnreadBg]}>
      {unread ? <View style={styles.unreadDot} /> : null}
      {children}
      {thumbnail ? <View style={styles.thumbnail} /> : null}
    </Pressable>
  );
}

function RichLine({ bold, text, boldEnd }: { bold: string; text: string; boldEnd?: string }) {
  return (
    <Text style={styles.line} numberOfLines={2}>
      <Text style={styles.lineBold}>{bold}</Text>
      {text}
      {boldEnd ? <Text style={styles.lineBold}>{boldEnd}</Text> : null}
    </Text>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.screenBg },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 8 },
  headerTitle: { fontFamily: interFont(700), fontSize: 30, color: '#fff', letterSpacing: -0.9 },
  markReadPill: { height: 30, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 12, borderRadius: 15, borderWidth: 1, borderColor: colors.border },
  markReadText: { fontFamily: interFont(600), fontSize: 12, color: 'rgba(255,255,255,.75)', letterSpacing: -0.1 },

  sectionLabelRow: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 20, paddingTop: 26 },
  sectionLabel: { fontFamily: interFont(650), fontSize: 11, letterSpacing: 1.1, color: 'rgba(255,255,255,.34)', paddingHorizontal: 20, paddingTop: 26 },
  unreadCountLabel: { fontFamily: interFont(650), fontSize: 11, letterSpacing: 0.4, color: 'rgba(255,255,255,.28)' },

  row: { position: 'relative', flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 13, paddingLeft: 20, paddingRight: 16 },
  rowUnreadBg: { backgroundColor: 'rgba(255,255,255,.028)' },
  unreadDot: { position: 'absolute', left: 8, top: '50%', marginTop: -2.5, width: 5, height: 5, borderRadius: 3, backgroundColor: '#fff' },
  rowBody: { flex: 1, minWidth: 0 },
  line: { fontFamily: interFont(400), fontSize: 14, color: '#fff', letterSpacing: -0.2, lineHeight: 18 },
  lineBold: { fontFamily: interFont(660) },
  subRow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 4 },
  subText: { fontFamily: interFont(400), fontSize: 11.5, color: 'rgba(255,255,255,.42)', marginTop: 4 },
  liveInline: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  liveInlineText: { fontFamily: interFont(650), fontSize: 10, letterSpacing: 0.6, color: colors.amber },
  time: { fontFamily: interFont(400), fontSize: 11, color: 'rgba(255,255,255,.3)' },
  thumbnail: { width: 38, height: 38, borderRadius: 11, backgroundColor: '#1c2029' },
  liveIconTile: { width: 38, height: 38, borderRadius: 12, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(242,160,61,.4)', backgroundColor: 'rgba(242,160,61,.1)' },
  borderedInitials: { width: 38, height: 38, borderRadius: 11, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: colors.border },
  borderedInitialsText: { fontFamily: interFont(650), fontSize: 11, color: 'rgba(255,255,255,.7)' },
});
