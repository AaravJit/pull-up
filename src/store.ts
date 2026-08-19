import { create } from 'zustand';

export type FriendKey = 'maya' | 'dre' | 'kenji';
export type MeetKey = 'meetSutter' | 'meetArden';
export type Selection = FriendKey | MeetKey | null;
export type VehicleKey = 'bmw' | 'gsxr' | 'rx7';
export type SharingOption = 'Off' | 'Friends' | 'Crew' | 'Cruise';

export interface Friend {
  name: string;
  crew: string;
  status: string;
  vehicle: string;
  vehicleMeta: string;
  badge: string;
}

export const friends: Record<FriendKey, Friend> = {
  maya: {
    name: 'Maya',
    crew: 'NIGHT SHIFT',
    status: 'Parked · Midtown · 0.6 mi',
    vehicle: '2003 Nissan Silvia S15',
    vehicleMeta: 'Spec-R',
    badge: 'S15',
  },
  dre: {
    name: 'Dre',
    crew: 'NIGHT SHIFT',
    status: 'Rolling · 16th St · 1.4 mi',
    vehicle: '2019 Yamaha MT-09',
    vehicleMeta: 'SP',
    badge: 'MT',
  },
  kenji: {
    name: 'Kenji',
    crew: 'CREW',
    status: 'Parked · Oak Park · 2.1 mi',
    vehicle: '1998 Integra Type R',
    vehicleMeta: 'DC2',
    badge: 'DC2',
  },
};

export interface Vehicle {
  name: string;
  badge: string;
  meta: string;
}

export const garage: Record<VehicleKey, Vehicle> = {
  bmw: { name: '2014 BMW 320i xDrive', badge: 'F30', meta: 'F30 · N20' },
  gsxr: { name: '2001 Suzuki GSX-R750', badge: 'K1', meta: 'K1' },
  rx7: { name: '1994 Mazda RX-7', badge: 'FD', meta: 'FD3S · 13B-REW' },
};

export const drivingOrder: VehicleKey[] = ['bmw', 'gsxr', 'rx7'];

export interface MeetSheetContent {
  title: string;
  venue: string;
  distance: string;
  timing: string;
  turnout: string;
  live: boolean;
  friendsHere: string;
  hostInitials: string;
  hostName: string;
  verified: boolean;
}

export const meets: Record<MeetKey, MeetSheetContent> = {
  meetSutter: {
    title: 'Sac Nights',
    venue: 'Sutter Lot · Midtown',
    distance: '0.8 mi',
    timing: 'Started 9:15 PM',
    turnout: '~40 here',
    live: true,
    friendsHere: 'Maya, Kenji +1 are here',
    hostInitials: 'GC',
    hostName: 'Gearbox Collective',
    verified: true,
  },
  meetArden: {
    title: 'Cars & Coffee Arden',
    venue: 'Arden Fair lot · North Sac',
    distance: '4.2 mi',
    timing: 'Sat 7:30 AM',
    turnout: 'RSVP to see turnout',
    live: false,
    friendsHere: 'Maya is going',
    hostInitials: 'AF',
    hostName: 'Arden Fair Cars & Coffee',
    verified: false,
  },
};

interface PullUpState {
  sel: Selection;
  sharingOpen: boolean;
  sharing: SharingOption;
  going: boolean;
  driving: VehicleKey;
  unread: number;

  selectMeet: (key: MeetKey) => void;
  selectFriend: (key: FriendKey) => void;
  dismiss: () => void;
  toggleSharing: () => void;
  setSharing: (opt: SharingOption) => void;
  cycleVehicle: () => void;
  setDriving: (key: VehicleKey) => void;
  togglePullUp: () => void;
  markActivityRead: () => void;
}

export const usePullUpStore = create<PullUpState>((set, get) => ({
  sel: null,
  sharingOpen: false,
  sharing: 'Friends',
  going: false,
  driving: 'bmw',
  unread: 3,

  selectMeet: (key) => set({ sel: key, sharingOpen: false, going: false }),
  selectFriend: (key) => set({ sel: key, sharingOpen: false }),
  dismiss: () => set({ sel: null, sharingOpen: false }),
  toggleSharing: () => set({ sel: null, sharingOpen: !get().sharingOpen }),
  setSharing: (opt) => set({ sharing: opt, sharingOpen: false }),
  cycleVehicle: () =>
    set({
      driving: drivingOrder[(drivingOrder.indexOf(get().driving) + 1) % drivingOrder.length],
    }),
  setDriving: (key) => set({ driving: key }),
  togglePullUp: () => set({ going: !get().going }),
  markActivityRead: () => set({ unread: 0 }),
}));

export const sharingOptions: { label: SharingOption; note: string }[] = [
  { label: 'Off', note: 'Invisible on the map' },
  { label: 'Friends', note: 'Everyone you follow both ways' },
  { label: 'Crew', note: 'Night Shift only' },
  { label: 'Cruise', note: 'Ends when the cruise ends' },
];
