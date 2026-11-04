/* 英雄详情（原生实现）
 * ---------------------------------------------------------------------------
 * 数据：/api/tools/heroes（133 位英雄）+ /api/tools/hero?id=<id>（皮肤大图）
 * 布局：
 *   sm / md ：网格 → 点选后整屏进入详情（顶部返回）
 *   lg      ：左侧网格 + 右侧详情双窗格
 * 皮肤区横向滑动；点图看大图（全屏遮罩，再点关闭）。
 */
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { NetStore } from '../data/NetStore';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { CHIP_ALL, ChipOpt, ChipRow, chipOf, orderedKeys } from '../common/ChipRow';
import { clockText, Ui } from '../common/Ui';
import { HeroAttr, HeroBrief, HeroDetail, HeroResp, HeroSkill, HeroesResp, SkinItem } from '../data/Models';

const HEROES_KEY: string = '/api/tools/heroes';

/** 类型 / 分路的展示顺序（官网口径，固定下来避免每次刷新顺序乱跳） */
const TYPE_ORDER: string[] = ['战士', '法师', '刺客', '射手', '坦克', '辅助'];
const LANE_ORDER: string[] = ['对抗路', '中路', '打野', '发育路', '游走'];

class HeroVM {
  id: number;
  name: string;
  icon: string;
  initial: string;
  types: string[];
  lanes: string[];
  title: string;
  pinyin: string;

  constructor(h: HeroBrief) {
    this.id = h.id;
    this.name = h.name;
    this.icon = ImageRepo.src(h.icon, 120);
    this.initial = h.name.length > 0 ? h.name.substring(0, 1) : '?';
    this.types = h.types ?? [];
    this.lanes = h.lanes ?? [];
    this.title = h.title ?? '';
    this.pinyin = h.pinyin ?? '';
  }
}

class SkinVM {
  name: string;
  uri: string;

  constructor(sk: SkinItem) {
    this.name = sk.name ?? '';
    const raw: string = sk.big ?? sk.bigAlt ?? '';
    this.uri = ImageRepo.src(raw, 640);
  }
}

class DetailVM {
  name: string;
  title: string;
  icon: string;
  tags: string[];
  lanes: string[];
  skins: SkinVM[];
  /** 属性评分（生存 / 攻击 / 技能 / 难度），空 = 官网未提供 */
  attrs: HeroAttr[];
  /** 技能列表（名称 / 冷却 / 消耗 / 描述 / 图标） */
  skills: HeroSkill[];
  /** 背景故事（段落用 \n 分隔） */
  story: string;
  /** 历史上的 TA */
  history: string;
  /** 官网未建页标记 */
  partial: boolean;

  constructor(d: HeroDetail) {
    this.name = d.name;
    this.title = d.title ?? '';
    this.icon = ImageRepo.src(d.icon, 160);
    this.tags = d.types ?? [];
    this.lanes = d.lanes ?? [];
    const out: SkinVM[] = [];
    if (d.skins) {
      for (let i = 0; i < d.skins.length; i++) {
        out.push(new SkinVM(d.skins[i]));
      }
    }
    this.skins = out;
    this.attrs = d.attr ?? [];
    this.skills = d.skills ?? [];
    this.story = d.story ?? '';
    this.history = d.history ?? '';
    this.partial = d.partial ?? false;
  }
}

@Component
export struct HeroPage {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @State heroes: HeroVM[] = [];
  @State keyword: string = '';
  @State typeKey: string = CHIP_ALL;
  @State laneKey: string = CHIP_ALL;
  @State selectedId: number = 0;
  @State vm: DetailVM | null = null;
  @State preview: string = '';
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;

  aboutToAppear(): void {
    this.fill(BundleStore.api<HeroesResp>(HEROES_KEY));
    this.online = NetStore.stampOf(HEROES_KEY) > 0;
    // 进入页面即后台联网刷新官网英雄库（成功后热更新列表与状态行）
    this.refresh();
  }

  /** 把接口数据铺进状态（首次进入 / 联网刷新后都走这里） */
  private fill(r: HeroesResp | null): void {
    const list = r ? r.heroes : [];
    const out: HeroVM[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(new HeroVM(list[i]));
    }
    this.heroes = out;
  }

  private async refresh(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const r = await NetStore.refresh<HeroesResp>(HEROES_KEY, true);
    if (r.data) {
      this.fill(r.data);
    }
    this.online = r.ok || NetStore.stampOf(HEROES_KEY) > 0;
    this.loading = false;
  }

  private statusText(): string {
    const at: number = NetStore.stampOf(HEROES_KEY);
    if (at > 0) {
      return `在线 · ${clockText(at)} 更新`;
    }
    return `离线包 · ${this.heroes.length} 位英雄`;
  }

  /** 关键词 + 类型 + 分路 三重过滤后的列表 */
  private list(): HeroVM[] {
    const kw: string = this.keyword.trim();
    const out: HeroVM[] = [];
    for (let i = 0; i < this.heroes.length; i++) {
      const h: HeroVM = this.heroes[i];
      if (!this.matchHero(h, this.typeKey, this.laneKey)) {
        continue;
      }
      if (kw.length > 0 && !this.hitKeyword(h, kw)) {
        continue;
      }
      out.push(h);
    }
    return out;
  }

  /** 类型 / 分路命中判断（all = 不过滤） */
  private matchHero(h: HeroVM, typeKey: string, laneKey: string): boolean {
    if (typeKey !== CHIP_ALL && h.types.indexOf(typeKey) < 0) {
      return false;
    }
    if (laneKey !== CHIP_ALL && h.lanes.indexOf(laneKey) < 0) {
      return false;
    }
    return true;
  }

  /** 搜索命中：英雄名 / 称号 / 拼音 */
  private hitKeyword(h: HeroVM, kw: string): boolean {
    if (h.name.indexOf(kw) >= 0) {
      return true;
    }
    if (h.title.length > 0 && h.title.indexOf(kw) >= 0) {
      return true;
    }
    if (h.pinyin.length > 0 && h.pinyin.indexOf(kw.toLowerCase()) >= 0) {
      return true;
    }
    return false;
  }

  /** 给定「类型 + 分路」组合下有多少位英雄（用于标签上的数量角标） */
  private countWith(typeKey: string, laneKey: string): number {
    let n: number = 0;
    for (let i = 0; i < this.heroes.length; i++) {
      if (this.matchHero(this.heroes[i], typeKey, laneKey)) {
        n++;
      }
    }
    return n;
  }

  /** 数据里出现过的类型（按官网固定顺序） */
  private presentTypes(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.heroes.length; i++) {
      const ts: string[] = this.heroes[i].types;
      for (let j = 0; j < ts.length; j++) {
        if (out.indexOf(ts[j]) < 0) {
          out.push(ts[j]);
        }
      }
    }
    return orderedKeys(out, TYPE_ORDER);
  }

  /** 数据里出现过的分路（按官网固定顺序） */
  private presentLanes(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.heroes.length; i++) {
      const ls: string[] = this.heroes[i].lanes;
      for (let j = 0; j < ls.length; j++) {
        if (out.indexOf(ls[j]) < 0) {
          out.push(ls[j]);
        }
      }
    }
    return orderedKeys(out, LANE_ORDER);
  }

  private typeOpts(): ChipOpt[] {
    const keys: string[] = this.presentTypes();
    const out: ChipOpt[] = [];
    out.push(chipOf(CHIP_ALL, '全部类型', `${this.countWith(CHIP_ALL, this.laneKey)}`));
    for (let i = 0; i < keys.length; i++) {
      out.push(chipOf(keys[i], keys[i], `${this.countWith(keys[i], this.laneKey)}`));
    }
    return out;
  }

  private laneOpts(): ChipOpt[] {
    const keys: string[] = this.presentLanes();
    const out: ChipOpt[] = [];
    out.push(chipOf(CHIP_ALL, '全部分路', `${this.countWith(this.typeKey, CHIP_ALL)}`));
    for (let i = 0; i < keys.length; i++) {
      out.push(chipOf(keys[i], keys[i], `${this.countWith(this.typeKey, keys[i])}`));
    }
    return out;
  }

  /** 是否有筛选生效（决定是否显示「重置」） */
  private filtered(): boolean {
    return this.typeKey !== CHIP_ALL || this.laneKey !== CHIP_ALL || this.keyword.trim().length > 0;
  }

  private resetFilter(): void {
    this.typeKey = CHIP_ALL;
    this.laneKey = CHIP_ALL;
    this.keyword = '';
  }

  private open(id: number): void {
    this.selectedId = id;
    const r = BundleStore.api<HeroResp>(`/api/tools/hero?id=${id}`);
    this.vm = r ? new DetailVM(r.hero) : null;
    // 后台联网拉官网详情（技能 / 属性 / 背景），成功且仍停留在该英雄时热更新
    this.loadDetailLive(id);
  }

  private async loadDetailLive(id: number): Promise<void> {
    try {
      const r = await NetStore.refresh<HeroResp>(`/api/tools/hero?id=${id}`, false);
      if (r.data && r.data.hero && this.selectedId === id) {
        this.vm = new DetailVM(r.data.hero);
      }
    } catch (e) {
      /* 静默：详情已有快照兜底 */
    }
  }

  private cols(): string {
    const bp = DeviceEnv.bpOf(this.widthVp);
    if (bp === 'lg') {
      return '1fr 1fr 1fr 1fr 1fr 1fr';
    }
    if (bp === 'md') {
      return '1fr 1fr 1fr 1fr 1fr';
    }
    return '1fr 1fr 1fr 1fr';
  }

  @Builder
  private heroTile(h: HeroVM) {
    Column() {
      if (h.icon) {
        Image(h.icon)
          .width('100%')
          .aspectRatio(1)
          .borderRadius(Ui.R_SM)
          .objectFit(ImageFit.Cover)
      } else {
        Text(h.initial)
          .width('100%')
          .aspectRatio(1)
          .fontSize(18)
          .fontColor(Ui.MUTED)
          .textAlign(TextAlign.Center)
          .borderRadius(Ui.R_SM)
          .backgroundColor(Ui.PANEL_2)
      }
      Text(h.name)
        .fontSize(Ui.FS_SMALL)
        .fontColor(this.selectedId === h.id ? Ui.GOLD : Ui.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(4)
    .borderRadius(Ui.R_SM)
    .backgroundColor(this.selectedId === h.id ? Ui.PANEL_2 : Color.Transparent)
    .onClick(() => this.open(h.id))
  }

  @Builder
  private skinCard(sk: SkinVM) {
    Column() {
      if (sk.uri) {
        Image(sk.uri)
          .width('100%')
          .aspectRatio(16 / 9)
          .borderRadius(Ui.R_SM)
          .objectFit(ImageFit.Cover)
          .onClick(() => {
            this.preview = sk.uri;
          })
      }
      Text(sk.name)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
        .maxLines(1)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 4 })
    }
    .width(DeviceEnv.bpOf(this.widthVp) === 'sm' ? 150 : 200)
    .margin({ right: 8 })
  }

  @Builder
  private detailPanel() {
    /* @Builder 体内只能写 UI 语法（不能 return / 不能声明局部变量），
     * 所以空态与详情态拆成两个互斥的 if 块。 */
    if (!this.vm) {
      Column() {
        Text('选择英雄查看详情')
          .fontSize(Ui.FS_BODY)
          .fontColor(Ui.MUTED)
      }
      .width('100%')
      .padding(20)
    }
    if (this.vm) {
    Scroll() {
      Column() {
        Row() {
          if (this.vm.icon) {
            Image(this.vm.icon)
              .width(64)
              .height(64)
              .borderRadius(Ui.R_MD)
              .objectFit(ImageFit.Cover)
          }
          Column() {
            Text(this.vm.name)
              .fontSize(Ui.FS_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.TEXT)
            Text(this.vm.title)
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.GOLD)
              .margin({ top: 2 })
            Row() {
              ForEach(this.vm.tags, (t: string, i: number) => {
                Text(t)
                  .fontSize(Ui.FS_TINY)
                  .fontColor(Ui.TEXT)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(4)
                  .backgroundColor(Ui.PANEL_2)
                  .margin({ right: 4, top: 4 })
              }, (t: string, i: number) => `dt-${i}`)
              ForEach(this.vm.lanes, (l: string, i: number) => {
                Text(l)
                  .fontSize(Ui.FS_TINY)
                  .fontColor(Ui.BLUE)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(4)
                  .backgroundColor(Ui.PANEL_2)
                  .margin({ right: 4, top: 4 })
              }, (l: string, i: number) => `dl-${i}`)
            }
            .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .width('100%')

        // 属性评分（官网 herodetail 四项）
        if (this.vm.attrs.length > 0) {
          Text('属性评分')
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .width('100%')
            .margin({ top: 16, bottom: 8 })
          ForEach(this.vm.attrs, (a: HeroAttr, i: number) => {
            Row() {
              Text(a.label ?? '')
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.MUTED)
                .width(64)
              // 进度条：底轨 + 金色填充（value 0~100）
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor(Ui.PANEL_2)
                Row()
                  .width(`${Math.max(0, Math.min(100, a.value ?? 0))}%`)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor(Ui.GOLD)
              }
              .layoutWeight(1)
              Text(`${a.value ?? 0}`)
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.GOLD)
                .width(30)
                .textAlign(TextAlign.End)
                .margin({ left: 8 })
            }
            .width('100%')
            .margin({ bottom: 8 })
          }, (a: HeroAttr, i: number) => `at-${i}-${a.label}`)
        }

        // 技能（官网解析：名称 / 冷却 / 消耗 / 描述 / 图标）
        if (this.vm.skills.length > 0) {
          Text('技能')
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .width('100%')
            .margin({ top: 10, bottom: 8 })
          ForEach(this.vm.skills, (sk: HeroSkill, i: number) => {
            Row() {
              if (sk.icon && sk.icon.length > 0) {
                Image(sk.icon)
                  .width(44)
                  .height(44)
                  .borderRadius(8)
                  .objectFit(ImageFit.Cover)
              } else {
                Text(`${i + 1}`)
                  .width(44)
                  .height(44)
                  .borderRadius(8)
                  .fontSize(16)
                  .fontColor(Ui.GOLD)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(Ui.PANEL_2)
              }
              Column() {
                Row() {
                  Text(sk.name ?? '')
                    .fontSize(Ui.FS_SMALL)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Ui.TEXT)
                    .layoutWeight(1)
                  if (sk.cd && sk.cd.length > 0 && sk.cd !== '0') {
                    Text(`冷却 ${sk.cd}`)
                      .fontSize(Ui.FS_TINY)
                      .fontColor(Ui.MUTED)
                      .margin({ left: 6 })
                  }
                  if (sk.cost && sk.cost.length > 0 && sk.cost !== '0') {
                    Text(`消耗 ${sk.cost}`)
                      .fontSize(Ui.FS_TINY)
                      .fontColor(Ui.MUTED)
                      .margin({ left: 6 })
                  }
                }
                .width('100%')
                Text(sk.desc ?? '')
                  .fontSize(Ui.FS_TINY)
                  .fontColor(Ui.MUTED)
                  .width('100%')
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 10 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ bottom: 12 })
          }, (sk: HeroSkill, i: number) => `sk2-${i}-${sk.name}`)
        }

        // 背景故事（官网「英雄故事」，段落分段显示）
        if (this.vm.story.length > 0) {
          Text('背景故事')
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .width('100%')
            .margin({ top: 10, bottom: 8 })
          ForEach(this.vm.story.split('\n'), (p: string, i: number) => {
            Text(p)
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.TEXT)
              .lineHeight(20)
              .width('100%')
              .margin({ bottom: 6 })
          }, (p: string, i: number) => `st-${i}-${p.substring(0, 8)}`)
        }

        // 历史上的 TA（可选补充）
        if (this.vm.history.length > 0) {
          Text('历史上的TA')
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .width('100%')
            .margin({ top: 10, bottom: 8 })
          ForEach(this.vm.history.split('\n'), (p: string, i: number) => {
            Text(p)
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.MUTED)
              .lineHeight(20)
              .width('100%')
              .margin({ bottom: 6 })
          }, (p: string, i: number) => `hs-${i}-${p.substring(0, 8)}`)
        }

        if (this.vm.skins.length > 0) {
          Text(`皮肤 ${this.vm.skins.length}`)
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .width('100%')
            .margin({ top: 16, bottom: 8 })
          Scroll() {
            Row() {
              ForEach(this.vm.skins, (sk: SkinVM, i: number) => {
                this.skinCard(sk)
              }, (sk: SkinVM, i: number) => `sk-${i}-${sk.name}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }
      }
      .width('100%')
      .padding(12)
      .borderRadius(Ui.R_MD)
      .backgroundColor(Ui.PANEL)
    }
    }
  }

  @Builder
  private gridArea() {
    Scroll() {
      Column() {
        if (this.list().length === 0) {
          Text('没有符合条件的英雄')
            .fontSize(Ui.FS_SMALL)
            .fontColor(Ui.MUTED)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 24 })
        }
        Grid() {
          ForEach(this.list(), (h: HeroVM) => {
            GridItem() {
              this.heroTile(h)
            }
          }, (h: HeroVM) => `h-${h.id}`)
        }
        .columnsTemplate(this.cols())
        .columnsGap(DeviceEnv.gutter(DeviceEnv.bpOf(this.widthVp)))
        .rowsGap(DeviceEnv.gutter(DeviceEnv.bpOf(this.widthVp)))
        .width('100%')
      }
      .width('100%')
      .padding({
        top: this.headH + 8,
        bottom: this.bottomGap(),
      })
    }
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
  private inDetail(): boolean {
    return this.selectedId > 0 && this.vm !== null;
  }

  /** 底部留白：窄屏时底部页签已吞掉手势条高度，页面不再重复加安全区 */
  private bottomGap(): number {
    return this.widthVp >= DeviceEnv.MD_MAX ? this.safeBottom + 8 : 84 + this.safeBottom + 12;
  }

  build() {

    /* 悬浮毛玻璃页头：搜索 + 筛选浮在内容之上，滚动时内容从其下方穿过并模糊 */
    Stack({ alignContent: Alignment.Top }) {
      if (this.wide()) {
        Row() {
          Column() {
            this.gridArea()
          }
          .layoutWeight(1)

          Column() {
            this.detailPanel()
          }
          .layoutWeight(1)
          .height('100%')
          .padding({ top: this.headH + 8 })
          .margin({ left: this.gut() })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        .padding({
          left: this.pad(),
          right: this.pad(),
        })
      }

      if (!this.wide() && this.inDetail()) {
        Column() {
          Row() {
            Text('← 返回')
              .fontSize(Ui.FS_BODY)
              .fontColor(Ui.GOLD)
              .onClick(() => {
                this.selectedId = 0;
                this.vm = null;
              })
            Blank()
          }
          .width('100%')
          .margin({ top: this.headH + 8, bottom: 6 })

          Column() {
            this.detailPanel()
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .padding({
          bottom: this.bottomGap(),
          left: this.pad(),
          right: this.pad(),
        })
      }

      if (!this.wide() && !this.inDetail()) {
        Column() {
          this.gridArea()
        }
        .width('100%')
        .height('100%')
        .padding({
          left: this.pad(),
          right: this.pad(),
        })
      }

      Column() {
        TopBar({
          title: '英雄详情',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh();
          }
        })

        TextInput({ placeholder: '搜索英雄（名称 / 称号 / 拼音）', text: this.keyword })
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.TEXT)
          .placeholderColor(Ui.MUTED)
          .backgroundColor(Ui.CONTROL)
          .borderRadius(Ui.R_SM)
          .height(DeviceEnv.tapMinOf(this.widthVp))
          .width('100%')
          .onChange((v: string) => {
            this.keyword = v;
          })

        // 类型筛选
        ChipRow({
          opts: this.typeOpts(),
          active: this.typeKey,
          onPick: (k: string) => {
            this.typeKey = k;
          }
        })
        .margin({ top: 8 })

        // 分路筛选
        ChipRow({
          opts: this.laneOpts(),
          active: this.laneKey,
          onPick: (k: string) => {
            this.laneKey = k;
          }
        })
        .margin({ top: 6 })

        Row() {
          Text(`共 ${this.list().length} 位`)
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

      if (this.preview) {
        Stack() {
          Image(this.preview)
            .width('100%')
            .objectFit(ImageFit.Contain)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .onClick(() => {
          this.preview = '';
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Ui.BG)
  }
}
