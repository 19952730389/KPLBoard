/* 铭文（原生实现）
 * ---------------------------------------------------------------------------
 * 数据：/api/tools/runes（离线快照 + 联网实时覆盖，顶部条可手动刷新）
 * 功能：颜色筛选 + 等级筛选 + 按颜色分组展示（默认分组）
 * 布局：颜色标签 + 等级下拉 + 分组开关；自适应网格（sm 2 列 / md 3 列 / lg 4 列）
 */
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { NetStore } from '../data/NetStore';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { CHIP_ALL, ChipOpt, ChipRow, chipAccent } from '../common/ChipRow';
import { MENU_MATERIAL_OFF, clockText, Ui } from '../common/Ui';
import { RuneColor, RuneItem, RunesResp } from '../data/Models';

const RUNES_KEY: string = '/api/tools/runes';

class RuneVM {
  name: string;
  subText: string;
  accent: string;
  desc: string;
  lines: string[];
  icon: string;
  colorKey: string;
  grade: number;

  constructor(it: RuneItem, accent: string) {
    this.name = it.name;
    this.subText = `${it.colorName ?? ''}${it.grade ? ' · ' + it.grade + '级' : ''}`;
    this.accent = accent;
    this.desc = it.desc ?? '';
    this.lines = it.lines ?? [];
    this.icon = ImageRepo.src(it.icon, 96);
    this.colorKey = it.color ?? '';
    this.grade = it.grade ?? 0;
  }
}

/** 按颜色分组后的一个分组 */
class RuneGroupVM {
  key: string;
  name: string;
  accent: string;
  desc: string;
  countText: string;
  items: RuneVM[];

  constructor(key: string, name: string, accent: string, desc: string, items: RuneVM[]) {
    this.key = key;
    this.name = name;
    this.accent = accent;
    this.desc = desc;
    this.countText = `${items.length} 枚`;
    this.items = items;
  }
}

@Component
export struct RunesPage {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @State all: RuneVM[] = [];
  @State colors: RuneColor[] = [];
  @State colorKey: string = CHIP_ALL;
  @State grade: number = 0;
  @State groupByColor: boolean = true;
  @State note: string = '';
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;

  aboutToAppear(): void {
    this.fill(BundleStore.api<RunesResp>(RUNES_KEY));
    this.online = NetStore.stampOf(RUNES_KEY) > 0;
    // 进入页面即后台联网刷新官网铭文库
    this.refresh();
  }

  /** 把接口数据铺进状态（首次进入 / 联网刷新后都走这里） */
  private fill(r: RunesResp | null): void {
    const list = r?.list ?? [];
    const cs = r?.colors ?? [];
    const vms: RuneVM[] = [];
    for (let i = 0; i < list.length; i++) {
      vms.push(new RuneVM(list[i], this.accentOf(cs, list[i].color)));
    }
    this.all = vms;
    this.colors = cs;
    this.note = r?.note ?? '';
  }

  private async refresh(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const r = await NetStore.refresh<RunesResp>(RUNES_KEY, true);
    if (r.data) {
      this.fill(r.data);
    }
    this.online = r.ok || NetStore.stampOf(RUNES_KEY) > 0;
    this.loading = false;
  }

  private statusText(): string {
    const at: number = NetStore.stampOf(RUNES_KEY);
    if (at > 0) {
      return `在线 · ${clockText(at)} 更新`;
    }
    return `离线包 · ${this.all.length} 条`;
  }

  private accentOf(cs: RuneColor[], key: string | undefined): string {
    for (let i = 0; i < cs.length; i++) {
      if (cs[i].key === key) {
        return cs[i].accent ?? Ui.GOLD;
      }
    }
    return Ui.GOLD;
  }

  /** 颜色 + 等级过滤后的扁平列表（按等级从高到低） */
  private visible(): RuneVM[] {
    const out: RuneVM[] = [];
    for (let i = 0; i < this.all.length; i++) {
      const vm: RuneVM = this.all[i];
      if (this.colorKey !== CHIP_ALL && vm.colorKey !== this.colorKey) {
        continue;
      }
      if (this.grade > 0 && vm.grade !== this.grade) {
        continue;
      }
      out.push(vm);
    }
    out.sort((a: RuneVM, b: RuneVM) => {
      if (a.grade !== b.grade) {
        return b.grade - a.grade;
      }
      return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    });
    return out;
  }

  /** 按颜色分组（组内同样等级从高到低） */
  private groups(): RuneGroupVM[] {
    const flat: RuneVM[] = this.visible();
    const out: RuneGroupVM[] = [];
    // 先按接口给的 colors 顺序；若离线包缺 colors 则退回数据里出现的顺序
    const seen: string[] = [];
    for (let i = 0; i < this.colors.length; i++) {
      const c: RuneColor = this.colors[i];
      if (this.colorKey !== CHIP_ALL && c.key !== this.colorKey) {
        continue;
      }
      const items: RuneVM[] = [];
      for (let j = 0; j < flat.length; j++) {
        if (flat[j].colorKey === c.key) {
          items.push(flat[j]);
        }
      }
      if (items.length > 0) {
        out.push(new RuneGroupVM(c.key ?? '', c.name ?? '', c.accent ?? Ui.GOLD, c.desc ?? '', items));
      }
      seen.push(c.key ?? '');
    }
    for (let i = 0; i < flat.length; i++) {
      if (seen.indexOf(flat[i].colorKey) >= 0) {
        continue;
      }
      seen.push(flat[i].colorKey);
      const items: RuneVM[] = [];
      for (let j = 0; j < flat.length; j++) {
        if (flat[j].colorKey === flat[i].colorKey) {
          items.push(flat[j]);
        }
      }
      out.push(new RuneGroupVM(flat[i].colorKey, items[0].subText.split(' · ')[0], flat[i].accent, '', items));
    }
    return out;
  }

  private colorOpts(): ChipOpt[] {
    const out: ChipOpt[] = [];
    let all: number = 0;
    for (let i = 0; i < this.all.length; i++) {
      if (this.grade === 0 || this.all[i].grade === this.grade) {
        all++;
      }
    }
    out.push(chipAccent(CHIP_ALL, '全部颜色', Ui.GOLD, `${all}`));
    for (let i = 0; i < this.colors.length; i++) {
      const c: RuneColor = this.colors[i];
      let n: number = 0;
      for (let j = 0; j < this.all.length; j++) {
        if (this.all[j].colorKey === c.key && (this.grade === 0 || this.all[j].grade === this.grade)) {
          n++;
        }
      }
      out.push(chipAccent(c.key ?? '', c.name ?? '', c.accent ?? Ui.GOLD, `${n}`));
    }
    return out;
  }

  private gradeOpts(): SelectOption[] {
    const a: SelectOption = { value: '全部等级' };
    const b: SelectOption = { value: '1级' };
    const c: SelectOption = { value: '2级' };
    const d: SelectOption = { value: '3级' };
    const e: SelectOption = { value: '4级' };
    const f: SelectOption = { value: '5级' };
    return [a, b, c, d, e, f];
  }

  private gradeLabel(): string {
    return this.grade > 0 ? `${this.grade}级` : '全部等级';
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

  @Builder
  private runeCard(vm: RuneVM) {
    Column() {
      Row() {
        if (vm.icon) {
          Image(vm.icon)
            .width(40)
            .height(40)
            .borderRadius(20)
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
          Text(vm.subText)
            .fontSize(Ui.FS_TINY)
            .fontColor(vm.accent)
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
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
      }
      ForEach(vm.lines, (l: string, i: number) => {
        Text(l)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.TEXT)
          .width('100%')
          .maxLines(1)
          .margin({ top: 2 })
      }, (l: string, i: number) => `rl-${i}`)
    }
    .width('100%')
    .padding(10)
    .borderRadius(Ui.R_MD)
    .backgroundColor(Ui.PANEL)
  }

  @Builder
  private groupHeader(g: RuneGroupVM) {
    Row() {
      Row()
        .width(4)
        .height(16)
        .borderRadius(2)
        .backgroundColor(g.accent)
      Text(g.name)
        .fontSize(Ui.FS_SUB)
        .fontWeight(FontWeight.Bold)
        .fontColor(g.accent)
        .margin({ left: 8 })
      if (g.desc.length > 0) {
        Text(g.desc)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.MUTED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      Blank()
      Text(g.countText)
        .fontSize(Ui.FS_TINY)
        .fontColor(Ui.MUTED)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(Ui.R_SM)
    .backgroundColor(Ui.PANEL)
    .margin({ bottom: 6 })
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
          if (this.visible().length === 0) {
            Text('没有符合条件的铭文')
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.MUTED)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 24 })
          }

          // 分组模式：红 / 蓝 / 绿 三段，段头带本色标识
          if (this.groupByColor) {
            ForEach(this.groups(), (g: RuneGroupVM) => {
              Column() {
                this.groupHeader(g)
                Grid() {
                  ForEach(g.items, (vm: RuneVM, j: number) => {
                    GridItem() {
                      this.runeCard(vm)
                    }
                  }, (vm: RuneVM, j: number) => `rg-${g.key}-${j}-${vm.name}`)
                }
                .columnsTemplate(this.cols())
                .columnsGap(this.gut())
                .rowsGap(this.gut())
                .width('100%')
              }
              .width('100%')
              .margin({ bottom: this.gut() * 2 })
            }, (g: RuneGroupVM) => `gp-${g.key}`)
          }

          // 平铺模式：一个网格
          if (!this.groupByColor) {
            Grid() {
              ForEach(this.visible(), (vm: RuneVM, i: number) => {
                GridItem() {
                  this.runeCard(vm)
                }
              }, (vm: RuneVM, i: number) => `rn-${i}-${vm.name}`)
            }
            .columnsTemplate(this.cols())
            .columnsGap(this.gut())
            .rowsGap(this.gut())
            .width('100%')
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
          title: '铭文',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh();
          }
        })

        // 颜色筛选（标签底色 = 铭文本色）
        ChipRow({
          opts: this.colorOpts(),
          active: this.colorKey,
          onPick: (k: string) => {
            this.colorKey = k;
          }
        })
        .margin({ top: 8 })

        Row() {
          Select(this.gradeOpts())
            .value(this.gradeLabel())
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
              this.grade = value === '全部等级' ? 0 : Number(value.replace('级', ''));
            })

          // 分组开关：默认按颜色分组展示
          Row() {
            Text('按颜色分组')
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.TEXT)
              .margin({ right: 8 })
            Toggle({ type: ToggleType.Switch, isOn: this.groupByColor })
              .selectedColor(Ui.GOLD)
              .onChange((on: boolean) => {
                this.groupByColor = on;
              })
          }
          .margin({ left: 10 })
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          Text(`共 ${this.visible().length} 枚`)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
          if (this.colorKey !== CHIP_ALL || this.grade > 0) {
            Text('重置筛选')
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.GOLD)
              .margin({ left: 10 })
              .onClick(() => {
                this.colorKey = CHIP_ALL;
                this.grade = 0;
              })
          }
        }
        .width('100%')
        .margin({ top: 6 })

        if (this.note) {
          Text(this.note)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }

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
