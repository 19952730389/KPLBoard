/* 梯度榜（原生实现）
 * ---------------------------------------------------------------------------
 * 数据：/api/tools/gradient?event=<id>（离线快照 + 联网实时覆盖，顶部条可手动刷新）
 * 布局：sm 2 列 / md 3 列 / lg 5 列；点击卡片展开「使用选手」。
 */
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { NetStore } from '../data/NetStore';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { CHIP_ALL, ChipOpt, ChipRow, chipOf, orderedKeys } from '../common/ChipRow';
import { clockText, Ui, numText, pctText } from '../common/Ui';
import { EventPicker } from '../common/EventPicker';
import { GradientItem, GradientResp } from '../data/Models';

/** 类型 / 分路的展示顺序（与英雄页保持一致） */
const TYPE_ORDER: string[] = ['战士', '法师', '刺客', '射手', '坦克', '辅助'];
const LANE_ORDER: string[] = ['对抗路', '中路', '打野', '发育路', '游走'];

class HeroVM {
  name: string;
  title: string;
  icon: string;
  gamesText: string;
  winText: string;
  kdaText: string;
  users: string[];
  types: string[];
  lanes: string[];

  constructor(it: GradientItem) {
    this.name = it.name;
    this.title = it.title ?? (it.types && it.types.length > 0 ? it.types[0] : '');
    this.icon = ImageRepo.src(it.icon, 96);
    this.gamesText = `出场 ${it.games ?? 0}`;
    this.winText = `胜率 ${pctText(it.winRate)}`;
    /* 官方（KPL 统计）通道不提供逐选手 KDA → 整段省略，而不是显示误导性的 0 */
    this.kdaText = (it.kda === undefined || it.kda === null) ? '' : `KDA ${numText(it.kda, 1)}`;
    this.users = it.userList ?? [];
    this.types = it.types ?? [];
    this.lanes = it.lanes ?? [];
  }
}

class TierVM {
  tier: string;
  label: string;
  countText: string;
  items: HeroVM[];

  constructor(tier: string, label: string, items: GradientItem[]) {
    this.tier = tier;
    this.label = label;
    this.countText = `${items.length} 位`;
    const out: HeroVM[] = [];
    for (let i = 0; i < items.length; i++) {
      out.push(new HeroVM(items[i]));
    }
    this.items = out;
  }
}

@Component
export struct GradientPage {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @State eventId: number = 0;
  @State data: GradientResp | null = null;
  @State expanded: string = '';
  @State typeKey: string = CHIP_ALL;
  @State laneKey: string = CHIP_ALL;
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;

  aboutToAppear(): void {
    this.eventId = this.defaultEvent();
    this.load();
    // 进入页面即后台联网刷新：KPL 官方统计随赛事进展更新，
    // 离线包只是「首次打开 / 无网」的兜底快照。
    this.refresh();
  }

  private cacheKey(): string {
    return `/api/tools/gradient?event=${this.eventId}`;
  }

  private defaultEvent(): number {
    const keys: string[] = ['1201', '1172', '1167'];
    for (let i = 0; i < keys.length; i++) {
      if (BundleStore.has(`/api/tools/gradient?event=${keys[i]}`)) {
        return Number(keys[i]);
      }
    }
    return 1201;
  }

  private load(): void {
    const r = BundleStore.api<GradientResp>(this.cacheKey());
    this.data = r;
    this.expanded = '';
    this.online = NetStore.stampOf(this.cacheKey()) > 0;
  }

  private async refresh(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const r = await NetStore.refresh<GradientResp>(this.cacheKey(), true);
    if (r.data) {
      this.data = r.data;
      this.expanded = '';
    }
    this.online = r.ok || NetStore.stampOf(this.cacheKey()) > 0;
    this.loading = false;
  }

  private statusText(): string {
    const at: number = NetStore.stampOf(this.cacheKey());
    if (at > 0) {
      return `在线 · ${clockText(at)} 更新`;
    }
    return `离线包 · ${this.data?.list?.length ?? 0} 位英雄`;
  }

  /** 类型 / 分路命中判断（all = 不过滤） */
  private matchItem(it: GradientItem, typeKey: string, laneKey: string): boolean {
    const ts: string[] = it.types ?? [];
    const ls: string[] = it.lanes ?? [];
    if (typeKey !== CHIP_ALL && ts.indexOf(typeKey) < 0) {
      return false;
    }
    if (laneKey !== CHIP_ALL && ls.indexOf(laneKey) < 0) {
      return false;
    }
    return true;
  }

  /** 当前筛选条件下的英雄集合 */
  private filteredList(): GradientItem[] {
    const list = this.data?.list ?? [];
    const out: GradientItem[] = [];
    for (let i = 0; i < list.length; i++) {
      if (this.matchItem(list[i], this.typeKey, this.laneKey)) {
        out.push(list[i]);
      }
    }
    return out;
  }

  /** 给定「类型 + 分路」组合下的英雄数（标签角标） */
  private countWith(typeKey: string, laneKey: string): number {
    const list = this.data?.list ?? [];
    let n: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (this.matchItem(list[i], typeKey, laneKey)) {
        n++;
      }
    }
    return n;
  }

  /** 类型 / 分路的完整候选（固定顺序优先，数据里多出的类型追加在后）。
   *  数据为空时也返回完整顺序——标签全部显示、数量为 0，而不是只剩「全部」。 */
  private presentKeys(lane: boolean): string[] {
    const list = this.data?.list ?? [];
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const arr: string[] = lane ? (list[i].lanes ?? []) : (list[i].types ?? []);
      for (let j = 0; j < arr.length; j++) {
        if (out.indexOf(arr[j]) < 0) {
          out.push(arr[j]);
        }
      }
    }
    const base: string[] = lane ? LANE_ORDER : TYPE_ORDER;
    const merged: string[] = base.slice();
    for (let i = 0; i < out.length; i++) {
      if (merged.indexOf(out[i]) < 0) {
        merged.push(out[i]);
      }
    }
    return merged;
  }

  private typeOpts(): ChipOpt[] {
    const keys: string[] = this.presentKeys(false);
    const out: ChipOpt[] = [];
    out.push(chipOf(CHIP_ALL, '全部类型', `${this.countWith(CHIP_ALL, this.laneKey)}`));
    for (let i = 0; i < keys.length; i++) {
      out.push(chipOf(keys[i], keys[i], `${this.countWith(keys[i], this.laneKey)}`));
    }
    return out;
  }

  private laneOpts(): ChipOpt[] {
    const keys: string[] = this.presentKeys(true);
    const out: ChipOpt[] = [];
    out.push(chipOf(CHIP_ALL, '全部分路', `${this.countWith(this.typeKey, CHIP_ALL)}`));
    for (let i = 0; i < keys.length; i++) {
      out.push(chipOf(keys[i], keys[i], `${this.countWith(this.typeKey, keys[i])}`));
    }
    return out;
  }

  private filtered(): boolean {
    return this.typeKey !== CHIP_ALL || this.laneKey !== CHIP_ALL;
  }

  private resetFilter(): void {
    this.typeKey = CHIP_ALL;
    this.laneKey = CHIP_ALL;
    this.expanded = '';
  }

  private tiers(): TierVM[] {
    const list = this.filteredList();
    const order: string[] = [];
    const map: Map<string, GradientItem[]> = new Map<string, GradientItem[]>();
    const labels: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < list.length; i++) {
      const it: GradientItem = list[i];
      const t: string = it.tier ?? '其他';
      let arr = map.get(t);
      if (arr === undefined) {
        arr = [];
        map.set(t, arr);
        order.push(t);
      }
      arr.push(it);
      if (!labels.has(t) && it.tierLabel) {
        labels.set(t, it.tierLabel);
      }
    }
    order.sort((a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0));
    const out: TierVM[] = [];
    for (let i = 0; i < order.length; i++) {
      const arr = map.get(order[i]);
      out.push(new TierVM(order[i], labels.get(order[i]) ?? '', arr ?? []));
    }
    return out;
  }

  private cols(): string {
    const bp = DeviceEnv.bpOf(this.widthVp);
    if (bp === 'lg') {
      return '1fr 1fr 1fr 1fr 1fr';
    }
    if (bp === 'md') {
      return '1fr 1fr 1fr';
    }
    return '1fr 1fr';
  }

  private iconSize(): number {
    const bp = DeviceEnv.bpOf(this.widthVp);
    return bp === 'sm' ? 40 : 46;
  }

  @Builder
  private heroCard(vm: HeroVM) {
    Column() {
      Row() {
        if (vm.icon) {
          Image(vm.icon)
            .width(this.iconSize())
            .height(this.iconSize())
            .borderRadius(this.iconSize() / 2)
            .objectFit(ImageFit.Cover)
        } else {
          Text(vm.name.length > 0 ? vm.name.substring(0, 1) : '?')
            .width(this.iconSize())
            .height(this.iconSize())
            .fontSize(this.iconSize() * 0.4)
            .fontColor(Ui.MUTED)
            .textAlign(TextAlign.Center)
            .borderRadius(this.iconSize() / 2)
            .backgroundColor(Ui.PANEL_2)
        }
        Column() {
          Text(vm.name)
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(vm.title)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
      }
      .width('100%')

      Row() {
        Text(vm.gamesText)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
        Blank()
        Text(vm.winText)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.GOLD)
        if (vm.kdaText.length > 0) {
          Blank()
          Text(vm.kdaText)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
        }
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.expanded === vm.name && vm.users.length > 0) {
        Column() {
          ForEach(vm.users, (u: string, i: number) => {
            Text(u)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.TEXT)
              .width('100%')
              .margin({ top: 2 })
          }, (u: string, i: number) => `u-${i}-${u}`)
        }
        .width('100%')
        .margin({ top: 8 })
        .padding(8)
        .borderRadius(Ui.R_SM)
        .backgroundColor(Ui.PANEL_2)
      }
    }
    .width('100%')
    .padding(10)
    .borderRadius(Ui.R_MD)
    .backgroundColor(Ui.PANEL)
    .onClick(() => {
      this.expanded = this.expanded === vm.name ? '' : vm.name;
    })
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private pad(): number {
    return DeviceEnv.padOf(this.widthVp);
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private gut(): number {
    return DeviceEnv.gutOf(this.widthVp);
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private empty(): boolean {
    return !this.data?.list || this.data.list.length === 0;
  }

  /** 有数据但被筛没了 */
  private noHit(): boolean {
    return !this.empty() && this.filteredList().length === 0;
  }

  /** 底部留白：窄屏时底部页签已吞掉手势条高度，页面不再重复加安全区 */
  private bottomGap(): number {
    return this.widthVp >= DeviceEnv.MD_MAX ? this.safeBottom + 8 : 84 + this.safeBottom + 12;
  }

  build() {

    /* 悬浮毛玻璃页头：赛事选择 + 筛选标签浮在内容之上 */
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column() {
          if (this.noHit()) {
            Column() {
              Text('没有符合筛选条件的英雄')
                .fontSize(Ui.FS_BODY)
                .fontColor(Ui.MUTED)
            }
            .width('100%')
            .height(160)
            .justifyContent(FlexAlign.Center)
            .margin({ top: 12 })
          }

          if (this.empty()) {
            Column() {
              Text('该赛事暂无梯度数据')
                .fontSize(Ui.FS_BODY)
                .fontColor(Ui.MUTED)
            }
            .width('100%')
            .height(200)
            .justifyContent(FlexAlign.Center)
          }

          if (!this.empty() && !this.noHit()) {
            Row() {
              Text(`选手 ${this.data?.totalPlayers ?? 0}`)
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.MUTED)
              Blank()
              Text(`战队 ${this.data?.totalTeams ?? 0}`)
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.MUTED)
              Blank()
              Text(`英雄选取 ${this.data?.totalHeroPicks ?? 0}`)
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.MUTED)
            }
            .width('100%')
            .padding(10)
            .borderRadius(Ui.R_SM)
            .backgroundColor(Ui.PANEL)
            .margin({ bottom: this.gut() })

            ForEach(this.tiers(), (g: TierVM) => {
              Column() {
                Row() {
                  Text(g.tier)
                    .fontSize(Ui.FS_SUB)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Ui.GOLD)
                  if (g.label) {
                    Text(g.label)
                      .fontSize(Ui.FS_SMALL)
                      .fontColor(Ui.MUTED)
                      .margin({ left: 8 })
                  }
                  Blank()
                  Text(g.countText)
                    .fontSize(Ui.FS_TINY)
                    .fontColor(Ui.MUTED)
                }
                .width('100%')
                .margin({ bottom: 6 })

                Grid() {
                  ForEach(g.items, (vm: HeroVM, j: number) => {
                    GridItem() {
                      this.heroCard(vm)
                    }
                  }, (vm: HeroVM, j: number) => `gi-${g.tier}-${j}-${vm.name}`)
                }
                .columnsTemplate(this.cols())
                .columnsGap(this.gut())
                .rowsGap(this.gut())
                .width('100%')
              }
              .width('100%')
              .margin({ bottom: this.gut() * 2 })
            }, (g: TierVM) => `tg-${g.tier}`)
          }
        }
        .width('100%')
        .padding({
          top: this.headH + 8,
          bottom: this.bottomGap(),
          left: this.pad(),
          right: this.pad(),
        })
      }
      .width('100%')
      .height('100%')

      Column() {
        TopBar({
          title: '梯度榜',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh();
          }
        })

        EventPicker({ eventId: this.eventId, kind: 'gradient', onPick: (id: number) => {
          this.eventId = id;
          this.load();
          // 换赛事后立即联网取该赛季数据（首次选中 2026 年度总决赛时尤为关键）
          this.refresh();
        } })

        // 英雄类型 / 分路筛选
        ChipRow({
          opts: this.typeOpts(),
          active: this.typeKey,
          onPick: (k: string) => {
            this.typeKey = k;
            this.expanded = '';
          }
        })
        .margin({ top: 10 })

        ChipRow({
          opts: this.laneOpts(),
          active: this.laneKey,
          onPick: (k: string) => {
            this.laneKey = k;
            this.expanded = '';
          }
        })
        .margin({ top: 6 })

        Row() {
          Text(`筛出 ${this.filteredList().length} 位`)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
          if (this.filtered()) {
            Text('重置筛选')
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.GOLD)
              .margin({ left: 10 })
              .onClick(() => this.resetFilter())
          }
        }
        .width('100%')
        .margin({ top: 6 })

        HeaderFade()
      }
      .width('100%')
      .padding({
        top: this.safeTop + 12,
        left: this.pad(),
        right: this.pad(),
      })
      .backgroundColor(Ui.GLASS)
      .backgroundEffect({ radius: Ui.BLUR, saturation: 1.5 })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.headH = Number(newArea.height);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Ui.BG)
  }
}
