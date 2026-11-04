/* 装备（原生实现）
 * ---------------------------------------------------------------------------
 * 数据：/api/tools/items（离线快照 + 联网实时覆盖，顶部条可手动刷新）
 * 功能：关键字搜索 + 装备类型筛选 + 购买价 / 售价排序
 * 布局：搜索框 + 类型横滑标签 + 排序下拉；自适应网格（sm 2 列 / md 3 列 / lg 4 列）
 */
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { NetStore } from '../data/NetStore';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { CHIP_ALL, ChipOpt, ChipRow, chipOf, orderedKeys } from '../common/ChipRow';
import { MENU_MATERIAL_OFF, clockText, Ui } from '../common/Ui';
import { ItemRow, ItemsResp } from '../data/Models';

const ITEMS_KEY: string = '/api/tools/items';

/** 官网装备分类顺序（与 typeId 1/2/3/4/5/7 对应） */
const ITEM_TYPE_ORDER: string[] = ['攻击', '法术', '防御', '移动', '打野', '游走'];

/** 排序方式：key → 下拉展示文案 */
const SORT_DEFAULT: string = 'default';
const SORT_BUY_ASC: string = 'buyAsc';
const SORT_BUY_DESC: string = 'buyDesc';
const SORT_SELL_ASC: string = 'sellAsc';
const SORT_SELL_DESC: string = 'sellDesc';

class ItemVM {
  name: string;
  type: string;
  /** 购买价（官网 total_price） */
  buy: number;
  /** 售价（官网 price） */
  sell: number;
  priceText: string;
  icon: string;
  desc: string;
  lines: string[];
  passives: string[];

  constructor(it: ItemRow) {
    this.name = it.name;
    this.type = it.type ?? '其他';
    this.buy = it.total ?? 0;
    this.sell = it.price ?? 0;
    this.priceText = `总价 ${this.buy > 0 ? this.buy : '-'}${this.sell > 0 ? ' · 售价 ' + this.sell : ''}`;
    this.icon = ImageRepo.src(it.icon, 96);
    this.desc = it.desc ?? '';
    this.lines = it.lines ?? [];
    const ps: string[] = [];
    if (it.passive) {
      ps.push(it.passive);
    }
    if (it.passives) {
      for (let i = 0; i < it.passives.length; i++) {
        ps.push(it.passives[i]);
      }
    }
    this.passives = ps;
  }
}

@Component
export struct ItemsPage {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @State items: ItemVM[] = [];
  @State types: string[] = [];
  @State type: string = CHIP_ALL;
  @State keyword: string = '';
  @State sort: string = SORT_DEFAULT;
  @State expanded: string = '';
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;

  aboutToAppear(): void {
    this.fill(BundleStore.api<ItemsResp>(ITEMS_KEY));
    this.online = NetStore.stampOf(ITEMS_KEY) > 0;
    // 进入页面即后台联网刷新官网装备库
    this.refresh();
  }

  /** 把接口数据铺进状态（首次进入 / 联网刷新后都走这里） */
  private fill(r: ItemsResp | null): void {
    const list = r ? r.items : [];
    const vms: ItemVM[] = [];
    const ts: string[] = [];
    for (let i = 0; i < list.length; i++) {
      vms.push(new ItemVM(list[i]));
      const t: string = list[i].type ?? '其他';
      if (ts.indexOf(t) < 0) {
        ts.push(t);
      }
    }
    this.items = vms;
    this.types = orderedKeys(ts, ITEM_TYPE_ORDER);
    this.expanded = '';
  }

  private async refresh(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const r = await NetStore.refresh<ItemsResp>(ITEMS_KEY, true);
    if (r.data) {
      this.fill(r.data);
    }
    this.online = r.ok || NetStore.stampOf(ITEMS_KEY) > 0;
    this.loading = false;
  }

  private statusText(): string {
    const at: number = NetStore.stampOf(ITEMS_KEY);
    if (at > 0) {
      return `在线 · ${clockText(at)} 更新`;
    }
    return `离线包 · ${this.items.length} 件`;
  }

  /** 搜索命中：装备名 / 描述 / 属性行 / 被动 */
  private hitKeyword(vm: ItemVM, kw: string): boolean {
    if (vm.name.indexOf(kw) >= 0) {
      return true;
    }
    if (vm.desc.length > 0 && vm.desc.indexOf(kw) >= 0) {
      return true;
    }
    for (let i = 0; i < vm.lines.length; i++) {
      if (vm.lines[i].indexOf(kw) >= 0) {
        return true;
      }
    }
    for (let i = 0; i < vm.passives.length; i++) {
      if (vm.passives[i].indexOf(kw) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 类型 + 关键字过滤，再按当前排序规则排序 */
  private visibleVMs(): ItemVM[] {
    const kw: string = this.keyword.trim();
    const out: ItemVM[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const vm: ItemVM = this.items[i];
      if (this.type !== CHIP_ALL && vm.type !== this.type) {
        continue;
      }
      if (kw.length > 0 && !this.hitKeyword(vm, kw)) {
        continue;
      }
      out.push(vm);
    }
    out.sort((a: ItemVM, b: ItemVM) => {
      if (this.sort === SORT_BUY_ASC) {
        return (a.buy || 0) - (b.buy || 0);
      }
      if (this.sort === SORT_BUY_DESC) {
        return (b.buy || 0) - (a.buy || 0);
      }
      if (this.sort === SORT_SELL_ASC) {
        return (a.sell || 0) - (b.sell || 0);
      }
      if (this.sort === SORT_SELL_DESC) {
        return (b.sell || 0) - (a.sell || 0);
      }
      return 0;
    });
    return out;
  }

  private typeOpts(): ChipOpt[] {
    const out: ChipOpt[] = [];
    let all: number = 0;
    for (let i = 0; i < this.items.length; i++) {
      if (this.hitKeyword(this.items[i], this.keyword.trim())) {
        all++;
      }
    }
    out.push(chipOf(CHIP_ALL, '全部类型', `${all}`));
    for (let i = 0; i < this.types.length; i++) {
      let n: number = 0;
      for (let j = 0; j < this.items.length; j++) {
        if (this.items[j].type === this.types[i] && this.hitKeyword(this.items[j], this.keyword.trim())) {
          n++;
        }
      }
      out.push(chipOf(this.types[i], this.types[i], `${n}`));
    }
    return out;
  }

  private sortOpts(): SelectOption[] {
    const a: SelectOption = { value: '默认排序' };
    const b: SelectOption = { value: '购买价 低→高' };
    const c: SelectOption = { value: '购买价 高→低' };
    const d: SelectOption = { value: '售价 低→高' };
    const e: SelectOption = { value: '售价 高→低' };
    return [a, b, c, d, e];
  }

  private sortLabel(): string {
    if (this.sort === SORT_BUY_ASC) {
      return '购买价 低→高';
    }
    if (this.sort === SORT_BUY_DESC) {
      return '购买价 高→低';
    }
    if (this.sort === SORT_SELL_ASC) {
      return '售价 低→高';
    }
    if (this.sort === SORT_SELL_DESC) {
      return '售价 高→低';
    }
    return '默认排序';
  }

  private pickSort(v: string): void {
    if (v === '购买价 低→高') {
      this.sort = SORT_BUY_ASC;
    } else if (v === '购买价 高→低') {
      this.sort = SORT_BUY_DESC;
    } else if (v === '售价 低→高') {
      this.sort = SORT_SELL_ASC;
    } else if (v === '售价 高→低') {
      this.sort = SORT_SELL_DESC;
    } else {
      this.sort = SORT_DEFAULT;
    }
    this.expanded = '';
  }

  /** 是否有筛选生效（决定是否显示「重置」） */
  private filtered(): boolean {
    return this.type !== CHIP_ALL || this.keyword.trim().length > 0 || this.sort !== SORT_DEFAULT;
  }

  private resetFilter(): void {
    this.type = CHIP_ALL;
    this.keyword = '';
    this.sort = SORT_DEFAULT;
    this.expanded = '';
  }

  private cols(): string {
    const bp = DeviceEnv.bpOf(this.widthVp);
    if (bp === 'lg') {
      return '1fr 1fr 1fr 1fr';
    }
    if (bp === 'md') {
      return '1fr 1fr 1fr';
    }
    return '1fr 1fr';
  }

  private iconSize(): number {
    return DeviceEnv.bpOf(this.widthVp) === 'sm' ? 38 : 44;
  }

  @Builder
  private itemCard(vm: ItemVM) {
    Column() {
      Row() {
        if (vm.icon) {
          Image(vm.icon)
            .width(this.iconSize())
            .height(this.iconSize())
            .borderRadius(Ui.R_SM)
            .objectFit(ImageFit.Contain)
            .backgroundColor(Ui.PANEL_2)
        }
        Column() {
          Text(vm.name)
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(vm.priceText)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.GOLD)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
      }
      .width('100%')

      if (vm.desc) {
        Text(vm.desc)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
          .width('100%')
          .maxLines(this.expanded === vm.name ? 20 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
      }

      if (this.expanded === vm.name) {
        Column() {
          Text(`${vm.type} · 购买 ${vm.buy > 0 ? vm.buy : '-'} · 售出 ${vm.sell > 0 ? vm.sell : '-'}`)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.GOLD)
            .width('100%')
            .margin({ bottom: 4 })
          ForEach(vm.lines, (l: string, i: number) => {
            Text(l)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.TEXT)
              .width('100%')
              .margin({ top: 2 })
          }, (l: string, i: number) => `il-${i}`)
          ForEach(vm.passives, (p: string, i: number) => {
            Text(p)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.ORANGE)
              .width('100%')
              .margin({ top: 2 })
          }, (p: string, i: number) => `ip-${i}`)
        }
        .width('100%')
        .margin({ top: 8 })
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

  /** 底部留白：窄屏时底部页签已吞掉手势条高度，页面不再重复加安全区 */
  private bottomGap(): number {
    return this.widthVp >= DeviceEnv.MD_MAX ? this.safeBottom + 8 : 84 + this.safeBottom + 12;
  }

  build() {

    /* 悬浮毛玻璃页头：筛选区浮在内容之上，滚动时内容从其下方穿过并模糊 */
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column() {
          if (this.visibleVMs().length === 0) {
            Text('没有符合条件的装备')
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.MUTED)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 24 })
          }
          Grid() {
            ForEach(this.visibleVMs(), (vm: ItemVM, i: number) => {
              GridItem() {
                this.itemCard(vm)
              }
            }, (vm: ItemVM, i: number) => `it-${i}-${vm.name}`)
          }
          .columnsTemplate(this.cols())
          .columnsGap(this.gut())
          .rowsGap(this.gut())
          .width('100%')
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
          title: '装备',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh();
          }
        })

        // 关键字搜索
        TextInput({ placeholder: '搜索装备（名称 / 属性 / 被动）', text: this.keyword })
          .fontSize(Ui.FS_SMALL)
          .fontColor(Ui.TEXT)
          .placeholderColor(Ui.MUTED)
          .backgroundColor(Ui.CONTROL)
          .borderRadius(Ui.R_SM)
          .height(DeviceEnv.tapMinOf(this.widthVp))
          .width('100%')
          .onChange((v: string) => {
            this.keyword = v;
            this.expanded = '';
          })

        // 装备类型筛选
        ChipRow({
          opts: this.typeOpts(),
          active: this.type,
          onPick: (k: string) => {
            this.type = k;
            this.expanded = '';
          }
        })
        .margin({ top: 8 })

        // 排序 + 命中数
        Row() {
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
            .backgroundColor(Ui.CONTROL)
            .borderRadius(Ui.R_SM)
            .height(DeviceEnv.tapMinOf(this.widthVp))
            .layoutWeight(1)
            .onSelect((index: number, value: string) => {
              this.pickSort(value);
            })
          Text(`${this.visibleVMs().length} 件`)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .margin({ left: 10 })
          if (this.filtered()) {
            Text('重置')
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.GOLD)
              .margin({ left: 10 })
              .onClick(() => this.resetFilter())
          }
        }
        .width('100%')
        .margin({ top: 8 })

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
