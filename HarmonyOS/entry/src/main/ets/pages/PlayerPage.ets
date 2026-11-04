/* 选手详情（原生实现）
 * ---------------------------------------------------------------------------
 * 数据：/api/tools/players?event=<id>（离线快照 + 联网实时覆盖，顶部条可手动刷新）
 * 布局：sm 点卡片就地展开详情；lg 左侧列表 + 右侧详情双窗格。
 */
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { NetStore } from '../data/NetStore';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { MENU_MATERIAL_OFF, Ui, clockText, numText, pctText, valText } from '../common/Ui';
import { EventPicker } from '../common/EventPicker';
import { PlayerItem, PlayerPoolItem, PlayersResp } from '../data/Models';

class PoolVM {
  name: string;
  icon: string;
  gamesText: string;
  winText: string;
  kdaText: string;

  constructor(it: PlayerPoolItem) {
    this.name = it.name ?? '-';
    this.icon = ImageRepo.src(it.icon, 64);
    this.gamesText = `${it.games ?? 0} 场`;
    this.winText = `胜率 ${pctText(it.winRate)}`;
    /* 官方（KPL 统计）通道不提供逐英雄 KDA → 显示「—」而不是误导性的 0 */
    this.kdaText = (it.kda === undefined || it.kda === null) ? 'KDA -' : `KDA ${numText(it.kda, 1)}`;
  }
}

class PlayerVM {
  name: string;
  teamText: string;
  kdaText: string;
  gamesText: string;
  winText: string;
  killText: string;
  deathText: string;
  assistText: string;
  attendText: string;
  goldText: string;
  dmgText: string;
  takenText: string;
  convText: string;
  goldPct: string;
  dmgPct: string;
  takenPct: string;
  durText: string;
  pool: PoolVM[];

  constructor(p: PlayerItem) {
    this.name = p.name;
    this.teamText = `${p.team ?? '-'}${p.lane ? ' · ' + p.lane : ''}`;
    this.kdaText = `KDA ${numText(p.kda, 1)}`;
    this.gamesText = `场次 ${p.games ?? 0}`;
    this.winText = pctText(p.winRate);
    this.killText = numText(p.kills, 1);
    /* 官方（KPL 统计）通道不提供场均死亡 / 助攻 / 分均经济 / 分均输出等绝对值，
       这些字段为 null → 显示「-」，而不是误导性的 0。 */
    this.deathText = numText(p.deaths, 1);
    this.assistText = numText(p.assists, 1);
    this.attendText = (p.attendRate ?? '').length > 0 ? p.attendRate ?? '-' : '-';
    this.goldText = valText(p.goldPerMin);
    this.dmgText = valText(p.dmgPerMin);
    this.takenText = valText(p.dmgTakenPerMin);
    this.convText = numText(p.dmgConversion, 1);
    this.goldPct = (p.goldPercent ?? '').length > 0 ? p.goldPercent ?? '-' : '-';
    this.dmgPct = (p.dmgPercent ?? '').length > 0 ? p.dmgPercent ?? '-' : '-';
    this.takenPct = (p.dmgTakenPercent ?? '').length > 0 ? p.dmgTakenPercent ?? '-' : '-';
    this.durText = (p.durationMin === undefined || p.durationMin === null) ? '-' : `${p.durationMin} 分`;
    const out: PoolVM[] = [];
    if (p.pool) {
      for (let i = 0; i < p.pool.length; i++) {
        out.push(new PoolVM(p.pool[i]));
      }
    }
    this.pool = out;
  }
}

@Component
export struct PlayerPage {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @State eventId: number = 1201;
  @State raw: PlayerItem[] = [];
  @State keyword: string = '';
  @State sortKey: string = 'rank';
  @State selected: string = '';
  /** 宽屏右侧详情当前选中的选手（用状态保存，build 里才能做非空收窄） */
  @State picked: PlayerVM | null = null;
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;

  aboutToAppear(): void {
    this.load();
    // 进入页面即后台联网刷新：KPL 官方统计随赛事进展更新，
    // 离线包只是「首次打开 / 无网」的兜底快照。
    this.refresh();
  }

  private cacheKey(): string {
    return `/api/tools/players?event=${this.eventId}`;
  }

  private load(): void {
    const r = BundleStore.api<PlayersResp>(this.cacheKey());
    this.raw = r?.players ?? [];
    this.selected = '';
    this.picked = null;
    this.online = NetStore.stampOf(this.cacheKey()) > 0;
  }

  private async refresh(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const r = await NetStore.refresh<PlayersResp>(this.cacheKey(), true);
    if (r.data) {
      this.raw = r.data.players ?? [];
      this.selected = '';
      this.picked = null;
    }
    this.online = r.ok || NetStore.stampOf(this.cacheKey()) > 0;
    this.loading = false;
  }

  private statusText(): string {
    const at: number = NetStore.stampOf(this.cacheKey());
    if (at > 0) {
      return `在线 · ${clockText(at)} 更新`;
    }
    return `离线包 · ${this.raw.length} 名选手`;
  }

  private list(): PlayerVM[] {
    const kw: string = this.keyword.trim();
    const picked: PlayerItem[] = [];
    for (let i = 0; i < this.raw.length; i++) {
      const p: PlayerItem = this.raw[i];
      if (kw.length > 0) {
        const nm: string = p.name ?? '';
        const tm: string = p.team ?? '';
        if (nm.indexOf(kw) < 0 && tm.indexOf(kw) < 0) {
          continue;
        }
      }
      picked.push(p);
    }
    picked.sort((a: PlayerItem, b: PlayerItem) => {
      if (this.sortKey === 'kda') {
        return (b.kda ?? 0) - (a.kda ?? 0);
      }
      if (this.sortKey === 'games') {
        return (b.games ?? 0) - (a.games ?? 0);
      }
      if (this.sortKey === 'dmg') {
        /* 官方通道不提供分均输出（null）→ 视为 -1 沉底，不与真实 0 混淆 */
        return (b.dmgPerMin ?? -1) - (a.dmgPerMin ?? -1);
      }
      return (a.rank ?? 999) - (b.rank ?? 999);
    });
    const out: PlayerVM[] = [];
    for (let i = 0; i < picked.length; i++) {
      out.push(new PlayerVM(picked[i]));
    }
    return out;
  }

  private current(): PlayerVM | null {
    const src = this.list();
    for (let i = 0; i < src.length; i++) {
      if (src[i].name === this.selected) {
        return src[i];
      }
    }
    return null;
  }

  private sortOpts(): SelectOption[] {
    const a: SelectOption = { value: '默认排名' };
    const b: SelectOption = { value: 'KDA' };
    const c: SelectOption = { value: '出场数' };
    const d: SelectOption = { value: '场均输出' };
    return [a, b, c, d];
  }

  private sortLabel(): string {
    if (this.sortKey === 'kda') {
      return 'KDA';
    }
    if (this.sortKey === 'games') {
      return '出场数';
    }
    if (this.sortKey === 'dmg') {
      return '场均输出';
    }
    return '默认排名';
  }

  @Builder
  private statCell(k: string, v: string) {
    Column() {
      Text(v)
        .fontSize(Ui.FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.TEXT)
      Text(k)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
  }

  @Builder
  private poolRow(vm: PoolVM) {
    Row() {
      if (vm.icon) {
        Image(vm.icon)
          .width(28)
          .height(28)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
      }
      Text(vm.name)
        .fontSize(Ui.FS_SMALL)
        .fontColor(Ui.TEXT)
        .margin({ left: 8 })
        .layoutWeight(1)
      Text(vm.gamesText)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
      Text(vm.winText)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.GOLD)
        .margin({ left: 8 })
      Text(vm.kdaText)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  private playerDetail(vm: PlayerVM) {
    Column() {
      Row() {
        this.statCell('分均经济', vm.goldText)
        this.statCell('分均输出', vm.dmgText)
        this.statCell('分均承伤', vm.takenText)
        this.statCell('输出转化', vm.convText)
      }
      .width('100%')

      Row() {
        this.statCell('经济占比', vm.goldPct)
        this.statCell('输出占比', vm.dmgPct)
        this.statCell('承伤占比', vm.takenPct)
        this.statCell('场均时长', vm.durText)
      }
      .width('100%')
      .margin({ top: 8 })

      if (vm.pool.length > 0) {
        Text(`英雄池 ${vm.pool.length}`)
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.GOLD)
          .width('100%')
          .margin({ top: 10, bottom: 4 })
        ForEach(vm.pool, (it: PoolVM, i: number) => {
          this.poolRow(it)
        }, (it: PoolVM, i: number) => `pool-${i}-${it.name}`)
      }
    }
    .width('100%')
    .margin({ top: 10 })
    .padding(10)
    .borderRadius(Ui.R_SM)
    .backgroundColor(Ui.BG)
  }

  @Builder
  private playerCard(vm: PlayerVM) {
    Column() {
      Row() {
        Column() {
          Text(vm.name)
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(vm.teamText)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(vm.kdaText)
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.GOLD)
        Text(vm.gamesText)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
          .margin({ left: 8 })
      }
      .width('100%')

      Row() {
        this.statCell('胜率', vm.winText)
        this.statCell('击杀', vm.killText)
        this.statCell('死亡', vm.deathText)
        this.statCell('助攻', vm.assistText)
        this.statCell('参团', vm.attendText)
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.selected === vm.name) {
        this.playerDetail(vm)
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(this.selected === vm.name ? Ui.PANEL_2 : Ui.PANEL)
    .onClick(() => {
      this.selected = this.selected === vm.name ? '' : vm.name;
      this.picked = this.selected === '' ? null : vm;
    })
  }

  @Builder
  private filterBar() {
    Row() {
      TextInput({ placeholder: '搜索选手 / 战队' })
        .fontSize(Ui.FS_SMALL)
        .fontColor(Ui.TEXT)
        .placeholderColor(Ui.MUTED)
        .backgroundColor(Ui.PANEL)
        .borderRadius(Ui.R_SM)
        .height(DeviceEnv.tapMin(DeviceEnv.bpOf(this.widthVp)))
        .layoutWeight(2)
        .onChange((v: string) => {
          this.keyword = v;
        })
      Select(this.sortOpts())
        .value(this.sortLabel())
        .font({ size: Ui.FS_SMALL })
        .fontColor(Ui.TEXT)
        .optionFontColor(Ui.TEXT)
        .selectedOptionFontColor(Ui.GOLD)
        .optionBgColor(Color.Transparent)
        .selectedOptionBgColor(Ui.PANEL_2)
        .menuBackgroundColor(Ui.PANEL)
        .menuSystemMaterial(MENU_MATERIAL_OFF)
        .menuBackgroundBlurStyleOptions({ colorMode: Ui.MENU_CM })
        .divider({ strokeWidth: 1, color: Ui.LINE, startMargin: 12, endMargin: 12 })
        .backgroundColor(Ui.PANEL)
        .borderRadius(Ui.R_SM)
        .height(DeviceEnv.tapMin(DeviceEnv.bpOf(this.widthVp)))
        .layoutWeight(1)
        .margin({ left: 8 })
        .onSelect((index: number, value: string) => {
          if (value === 'KDA') {
            this.sortKey = 'kda';
          } else if (value === '出场数') {
            this.sortKey = 'games';
          } else if (value === '场均输出') {
            this.sortKey = 'dmg';
          } else {
            this.sortKey = 'rank';
          }
        })
    }
    .width('100%')
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
  private wide(): boolean {
    return DeviceEnv.wideOf(this.widthVp);
  }

  /** 断点自适应取值：build() 内不能声明局部变量，统一走成员方法 */
  private empty(): boolean {
    return this.raw.length === 0;
  }

  /** 底部留白：窄屏时底部页签已吞掉手势条高度，页面不再重复加安全区 */
  private bottomGap(): number {
    return this.widthVp >= DeviceEnv.MD_MAX ? this.safeBottom + 8 : 84 + this.safeBottom + 12;
  }

  build() {

    /* 悬浮毛玻璃页头：赛事选择 + 搜索/排序浮在内容之上（各占一行，不再重叠） */
    Stack({ alignContent: Alignment.Top }) {
      if (this.empty()) {
        Column() {
          Text('该赛事暂无选手数据')
            .fontSize(Ui.FS_BODY)
            .fontColor(Ui.MUTED)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: this.headH })
      }

      if (!this.empty() && this.wide()) {
        Row() {
          Scroll() {
            Column() {
              ForEach(this.list(), (vm: PlayerVM, i: number) => {
                Column() {
                  this.playerCard(vm)
                }
                .width('100%')
                .margin({ bottom: this.gut() })
              }, (vm: PlayerVM, i: number) => `pl-${i}-${vm.name}`)
            }
            .width('100%')
            .padding({
              top: this.headH + 10,
              bottom: this.bottomGap(),
            })
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .height('100%')

          Scroll() {
            Column() {
              if (this.picked) {
                Text(this.picked.name)
                  .fontSize(Ui.FS_SUB)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Ui.TEXT)
                  .width('100%')
                this.playerDetail(this.picked)
              }
              if (!this.picked) {
                Text('选择左侧选手查看详情')
                  .fontSize(Ui.FS_BODY)
                  .fontColor(Ui.MUTED)
                  .width('100%')
                  .margin({ top: 20 })
              }
            }
            .width('100%')
            .padding({
              top: this.headH + 10,
              bottom: this.bottomGap(),
            })
          }
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .height('100%')
          .margin({ left: this.gut() })
        }
        .width('100%')
        .height('100%')
        .padding({
          left: this.pad(),
          right: this.pad(),
        })
        .alignItems(VerticalAlign.Top)
      }

      if (!this.empty() && !this.wide()) {
        Scroll() {
          Column() {
            ForEach(this.list(), (vm: PlayerVM, i: number) => {
              Column() {
                this.playerCard(vm)
              }
              .width('100%')
              .margin({ bottom: this.gut() })
            }, (vm: PlayerVM, i: number) => `ps-${i}-${vm.name}`)
          }
          .width('100%')
          .padding({
            top: this.headH + 10,
            bottom: this.bottomGap(),
            left: this.pad(),
            right: this.pad(),
          })
        }
        .width('100%')
        .height('100%')
      }

      Column() {
        TopBar({
          title: '选手详情',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh();
          }
        })

        EventPicker({ eventId: this.eventId, kind: 'players', onPick: (id: number) => {
          this.eventId = id;
          this.load();
          // 换赛事后立即联网取该赛季数据（首次选中 2026 年度总决赛时尤为关键）
          this.refresh();
        } })

        this.filterBar()

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
