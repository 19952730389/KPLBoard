/* 版本动态（原生实现）
 * ---------------------------------------------------------------------------
 * 数据：/api/patch?limit=8&what=feed（离线快照 + 联网实时覆盖）
 *
 * 三个子模块（对齐桌面端）：
 *   ① 公告        —— 官方公告流（标题 / 时间 / 版本号 / 标签）
 *   ② 英雄改动    —— 逐条英雄平衡性调整：头像、称号、增强/削弱/调整、改动明细
 *   ③ 装备改动    —— 逐条装备调整：图标、分类、方向、改动明细
 *   ④ 铭文改动    —— 只有当次版本确实有铭文改动时才出现
 *
 * 刷新：顶部条右侧的刷新按钮走 NetStore.refresh，成功即写入内存覆盖层并落盘，
 *      失败静默回退离线快照；顶部状态行会明确标出「在线 · HH:mm 更新」或「离线包」。
 */
import { common } from '@kit.AbilityKit';
import { BundleStore } from '../data/BundleStore';
import { ImageRepo } from '../data/ImageRepo';
import { NetStore } from '../data/NetStore';
import { ToolsUpstream } from '../data/ToolsUpstream';
import { DeviceEnv } from '../common/DeviceEnv';
import { HeaderFade } from '../common/HeaderFade';
import { TopBar } from '../common/TopBar';
import { StatusTag, clockText, dirOf, Ui } from '../common/Ui';
import { PatchChange, PatchDetail, PatchNote, PatchResp } from '../data/Models';

const PATCH_KEY: string = '/api/patch?limit=8&what=feed';

class ChangeVM {
  name: string;
  tag: string;
  icon: string;
  initial: string;
  round: boolean;
  dirText: string;
  dirColor: string;
  lines: string[];
  news: string;
  newsTime: string;
  newsUrl: string;

  constructor(c: PatchChange, round: boolean) {
    this.name = c.name ?? '未知';
    this.tag = round ? (c.title ?? '') : (c.type ?? c.section ?? '');
    this.icon = ImageRepo.src(c.icon, 96);
    this.initial = this.name.length > 0 ? this.name.substring(0, 1) : '?';
    this.round = round;
    const d: StatusTag = dirOf(c.dir);
    this.dirText = d.text;
    this.dirColor = d.color;
    this.lines = c.lines ?? (c.summary ? [c.summary] : []);
    this.news = c.newsTitle ?? '';
    this.newsTime = c.newsTime ?? '';
    this.newsUrl = c.newsUrl ?? '';
  }
}

@Component
export struct PatchPage {
  @StorageLink('dev.widthVp') widthVp: number = 360;
  @StorageLink('dev.safeBottom') safeBottom: number = 0;
  @StorageLink('dev.safeTop') safeTop: number = 0;
  @StorageLink('ui.themeMode') themeMode: string = 'dark';
  @State notes: PatchNote[] = [];
  @State changes: PatchChange[] = [];
  @State latestVersion: string = '';
  @State latestTime: string = '';
  @State tab: number = 0;
  @State loading: boolean = false;
  @State online: boolean = false;
  /** 悬浮页头实测高度：内容顶部据此让位（onAreaChange 回写） */
  @State headH: number = 0;
  /* 公告详情 */
  @State curNote: PatchNote | null = null;
  @State detail: PatchDetail | null = null;
  @State detailLoading: boolean = false;
  @State detailError: string = '';

  aboutToAppear(): void {
    this.apply(BundleStore.api<PatchResp>(PATCH_KEY));
    this.online = NetStore.stampOf(PATCH_KEY) > 0;
    // 进入页面即后台联网刷新官网公告（版本动态）
    this.refresh();
  }

  /* ---------------- 数据 ---------------- */

  private apply(r: PatchResp | null): void {
    if (!r) {
      this.notes = [];
      this.changes = [];
      return;
    }
    this.notes = r.notes ?? [];
    this.changes = r.changes ?? [];
    this.latestVersion = r.latestVersion ?? '';
    this.latestTime = r.latestTime ?? '';
  }

  private async refresh(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    const r = await NetStore.refresh<PatchResp>(PATCH_KEY, true);
    this.apply(r.data);
    this.online = r.ok || NetStore.stampOf(PATCH_KEY) > 0;
    this.loading = false;
  }

  private statusText(): string {
    const at: number = NetStore.stampOf(PATCH_KEY);
    if (at > 0) {
      return `在线 · ${clockText(at)} 更新`;
    }
    return `离线包 · ${this.latestTime ? this.latestTime : '暂无'} 快照`;
  }

  /* ---------------- 公告详情 ---------------- */

  /** 点开公告：记录当前公告并按 id 拉正文（端内直连官网，30 分钟内存缓存） */
  private openNote(n: PatchNote): void {
    this.curNote = n;
    this.detail = null;
    this.detailError = '';
    this.loadDetail(n.id ?? '');
  }

  private closeNote(): void {
    this.curNote = null;
    this.detail = null;
    this.detailError = '';
  }

  private async loadDetail(id: string): Promise<void> {
    if (id.length === 0) {
      this.detailError = '缺少公告编号，请通过官网原文查看';
      return;
    }
    this.detailLoading = true;
    try {
      const d = await ToolsUpstream.patchDetail(id, false);
      if (this.curNote !== null && (this.curNote.id ?? '') === id) {
        this.detail = d;
        if ((d.text ?? '').length === 0 && (d.changes ?? []).length === 0) {
          this.detailError = '公告正文暂未解析到，可通过官网原文查看';
        }
      }
    } catch (e) {
      if (this.curNote !== null && (this.curNote.id ?? '') === id) {
        this.detailError = '公告正文加载失败，可通过官网原文查看';
      }
    }
    this.detailLoading = false;
  }

  /** 用系统浏览器打开官网链接 */
  private openUrl(url: string): void {
    const u = url.trim();
    if (u.length === 0) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.openLink(u, { appLinkingOnly: false });
    } catch (e) {
      /* 打不开就忽略 */
    }
  }

  /** 详情页标题 / 时间 / 版本 / 官网链接（正文与列表信息合并取值） */
  private noteTitle(): string {
    return this.curNote !== null ? (this.curNote.title ?? '（无标题）') : '';
  }

  private noteTime(): string {
    return this.curNote !== null ? (this.curNote.time ?? '') : '';
  }

  private noteVersion(): string {
    const v = this.detail !== null ? (this.detail.version ?? '') : '';
    if (v.length > 0) {
      return v;
    }
    return this.curNote !== null ? (this.curNote.version ?? '') : '';
  }

  private noteUrl(): string {
    return this.curNote !== null ? (this.curNote.url ?? '') : '';
  }

  /** 详情正文段落 */
  private detailParas(): string[] {
    const t = this.detail !== null ? (this.detail.text ?? '') : '';
    if (t.length === 0) {
      return [];
    }
    return t.split('\n');
  }

  /** 详情结构化改动 → ChangeVM 列表（复用 changeCard 渲染） */
  private detailVMs(): ChangeVM[] {
    const d = this.detail;
    if (d === null) {
      return [];
    }
    const cs = d.changes ?? [];
    const out: ChangeVM[] = [];
    for (let i = 0; i < cs.length; i++) {
      out.push(new ChangeVM(cs[i], cs[i].kind === 'hero'));
    }
    return out;
  }

  /* ---------------- 分组 ---------------- */

  private ofKind(kind: string): PatchChange[] {
    const out: PatchChange[] = [];
    for (let i = 0; i < this.changes.length; i++) {
      if (this.changes[i].kind === kind) {
        out.push(this.changes[i]);
      }
    }
    return out;
  }

  private vms(list: PatchChange[], round: boolean): ChangeVM[] {
    const out: ChangeVM[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(new ChangeVM(list[i], round));
    }
    return out;
  }

  private heroVMs(): ChangeVM[] {
    return this.vms(this.ofKind('hero'), true);
  }

  private itemVMs(): ChangeVM[] {
    return this.vms(this.ofKind('item'), false);
  }

  private runeVMs(): ChangeVM[] {
    return this.vms(this.ofKind('rune'), false);
  }

  private tabNames(): string[] {
    const out: string[] = ['公告', '英雄改动', '装备改动'];
    if (this.runeVMs().length > 0) {
      out.push('铭文改动');
    }
    return out;
  }

  private tabCount(i: number): number {
    if (i === 0) {
      return this.notes.length;
    }
    if (i === 1) {
      return this.heroVMs().length;
    }
    if (i === 2) {
      return this.itemVMs().length;
    }
    return this.runeVMs().length;
  }

  private listOf(i: number): ChangeVM[] {
    if (i === 1) {
      return this.heroVMs();
    }
    if (i === 2) {
      return this.itemVMs();
    }
    if (i === 3) {
      return this.runeVMs();
    }
    return [];
  }

  /* ---------------- 视图 ---------------- */

  @Builder
  private seg(label: string, i: number) {
    Row() {
      Text(label)
        .fontSize(Ui.FS_SMALL)
        .fontColor(this.tab === i ? Ui.ON_GOLD : Ui.MUTED)
      Text(`${this.tabCount(i)}`)
        .fontSize(Ui.FS_TINY)
        .fontColor(this.tab === i ? Ui.ON_GOLD : Ui.MUTED)
        .margin({ left: 4 })
    }
    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .borderRadius(Ui.R_SM)
    .backgroundColor(this.tab === i ? Ui.GOLD : Ui.PANEL)
    .margin({ right: 8 })
    .onClick(() => {
      this.tab = i;
    })
  }

  @Builder
  private noteCard(n: PatchNote) {
    Column() {
      Text(n.title ?? '（无标题）')
        .fontSize(Ui.FS_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(Ui.TEXT)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        if (n.time) {
          Text(n.time)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
        }
        if (n.version) {
          Text(n.version)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.GOLD)
            .margin({ left: 8 })
        }
        Blank()
        if (n.kinds && n.kinds.length > 0) {
          ForEach(n.kinds, (k: string) => {
            Text(k === 'hero' ? '英雄' : k === 'item' ? '装备' : k === 'rune' ? '铭文' : k)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.BLUE)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor(Ui.PANEL_2)
              .margin({ left: 4 })
          }, (k: string, i: number) => `k-${i}-${k}`)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      if ((n.url ?? '').length > 0) {
        Row() {
          Text('点开查看详情')
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
          Blank()
          Text('官网原文 ↗')
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.GOLD)
            .onClick(() => this.openUrl(n.url ?? ''))
        }
        .width('100%')
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(Ui.PANEL)
    .onClick(() => this.openNote(n))
  }

  @Builder
  private changeCard(vm: ChangeVM) {
    Column() {
      Row() {
        if (vm.icon) {
          Image(vm.icon)
            .width(44)
            .height(44)
            .borderRadius(vm.round ? 22 : Ui.R_SM)
            .objectFit(ImageFit.Cover)
            .backgroundColor(Ui.PANEL_2)
        } else {
          Text(vm.initial)
            .width(44)
            .height(44)
            .fontSize(18)
            .fontColor(Ui.MUTED)
            .textAlign(TextAlign.Center)
            .borderRadius(vm.round ? 22 : Ui.R_SM)
            .backgroundColor(Ui.PANEL_2)
        }
        Column() {
          Text(vm.name)
            .fontSize(Ui.FS_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (vm.tag) {
            Text(vm.tag)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.MUTED)
              .maxLines(1)
              .margin({ top: 2 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })

        Text(vm.dirText)
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.ON_GOLD)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
          .backgroundColor(vm.dirColor)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column() {
        ForEach(vm.lines, (l: string) => {
          Row() {
            Text('·')
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.GOLD)
            Text(l)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.TEXT)
              .layoutWeight(1)
              .margin({ left: 4 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 4 })
        }, (l: string, i: number) => `cl-${i}-${l}`)
      }
      .width('100%')
      .padding(8)
      .borderRadius(Ui.R_SM)
      .backgroundColor(Ui.PANEL_2)
      .margin({ top: 10 })

      if (vm.news) {
        Row() {
          Text(vm.news)
            .fontSize(Ui.FS_TINY)
            .fontColor(Ui.MUTED)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (vm.newsTime) {
            Text(vm.newsTime)
              .fontSize(Ui.FS_TINY)
              .fontColor(Ui.MUTED)
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })
      }

      if (vm.newsUrl.length > 0) {
        Text('官网公告 ↗')
          .fontSize(Ui.FS_TINY)
          .fontColor(Ui.GOLD)
          .margin({ top: 6 })
          .onClick(() => this.openUrl(vm.newsUrl))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(Ui.R_MD)
    .backgroundColor(Ui.PANEL)
  }

  @Builder
  private changeList(list: ChangeVM[], empty: string) {
    if (list.length === 0) {
      Column() {
        Text(empty)
          .fontSize(Ui.FS_BODY)
          .fontColor(Ui.MUTED)
      }
      .width('100%')
      .padding({ top: 40, bottom: 40 })
    }
    ForEach(list, (vm: ChangeVM) => {
      Column() {
        this.changeCard(vm)
      }
      .width('100%')
      .margin({ bottom: this.gut() })
    }, (vm: ChangeVM, i: number) => `ch-${i}-${vm.name}`)
  }

  /* ---------------- 公告详情页 ---------------- */

  @Builder
  private detailNote() {
    Column() {
      Row() {
        Text('← 返回列表')
          .fontSize(Ui.FS_BODY)
          .fontColor(Ui.GOLD)
          .onClick(() => this.closeNote())
        Blank()
      }
      .width('100%')

      Scroll() {
        Column() {
          Text(this.noteTitle())
            .fontSize(Ui.FS_SUB)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.TEXT)
            .width('100%')

          Row() {
            if (this.noteTime().length > 0) {
              Text(this.noteTime())
                .fontSize(Ui.FS_TINY)
                .fontColor(Ui.MUTED)
            }
            if (this.noteVersion().length > 0) {
              Text(this.noteVersion())
                .fontSize(Ui.FS_TINY)
                .fontColor(Ui.GOLD)
                .margin({ left: 8 })
            }
            Blank()
          }
          .width('100%')
          .margin({ top: 6 })

          if (this.detailLoading && this.detail === null) {
            Column() {
              Text('正在加载公告正文…')
                .fontSize(Ui.FS_BODY)
                .fontColor(Ui.MUTED)
            }
            .width('100%')
            .padding({ top: 48, bottom: 48 })
          }

          if (!this.detailLoading && this.detailError.length > 0) {
            Text(this.detailError)
              .fontSize(Ui.FS_SMALL)
              .fontColor(Ui.ORANGE)
              .width('100%')
              .margin({ top: 10 })
          }

          if (this.detailParas().length > 0) {
            Column() {
              ForEach(this.detailParas(), (p: string, i: number) => {
                Text(p)
                  .fontSize(Ui.FS_SMALL)
                  .fontColor(Ui.TEXT)
                  .lineHeight(20)
                  .width('100%')
                  .margin({ bottom: 6 })
              }, (p: string, i: number) => `pp-${i}-${p.substring(0, 8)}`)
            }
            .width('100%')
            .padding(12)
            .borderRadius(Ui.R_MD)
            .backgroundColor(Ui.PANEL)
            .margin({ top: 10 })
          }

          if (this.detailVMs().length > 0) {
            Text(`调整条目 ${this.detailVMs().length}`)
              .fontSize(Ui.FS_BODY)
              .fontWeight(FontWeight.Bold)
              .fontColor(Ui.TEXT)
              .width('100%')
              .margin({ top: 14, bottom: 8 })
            ForEach(this.detailVMs(), (vm: ChangeVM, i: number) => {
              Column() {
                this.changeCard(vm)
              }
              .width('100%')
              .margin({ bottom: this.gut() })
            }, (vm: ChangeVM, i: number) => `dn-${i}-${vm.name}`)
          }

          if (this.noteUrl().length > 0) {
            Row() {
              Text('在官网查看原文 ↗')
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.ON_GOLD)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 12, bottom: 12 })
            .borderRadius(Ui.R_MD)
            .backgroundColor(Ui.GOLD)
            .margin({ top: 6 })
            .onClick(() => this.openUrl(this.noteUrl()))
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
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
  private maxW(): number {
    return DeviceEnv.bpOf(this.widthVp) === 'lg' ? 720 : 0;
  }

  /** 底部留白：窄屏时底部页签已吞掉手势条高度，页面不再重复加安全区 */
  private bottomGap(): number {
    return this.widthVp >= DeviceEnv.MD_MAX ? this.safeBottom + 8 : 84 + this.safeBottom + 12;
  }

  build() {
    // 超宽屏（平板横屏 / 外接显示器）限制阅读宽度，避免一行文字过长
    // 悬浮毛玻璃页头：标题区浮在内容之上，滚动时内容从其下方穿过并模糊
    Stack({ alignContent: Alignment.Top }) {
      if (this.curNote === null) {
      Scroll() {
        Column() {
          Row() {
            if (this.latestVersion) {
              Text(`当前版本 ${this.latestVersion}`)
                .fontSize(Ui.FS_SMALL)
                .fontColor(Ui.GOLD)
            }
            Blank()
            if (this.latestTime) {
              Text(this.latestTime)
                .fontSize(Ui.FS_TINY)
                .fontColor(Ui.MUTED)
            }
          }
          .width('100%')
          .padding(10)
          .borderRadius(Ui.R_SM)
          .backgroundColor(Ui.CONTROL)
          .margin({ bottom: this.gut() })

          Scroll() {
            Row() {
              ForEach(this.tabNames(), (t: string, i: number) => {
                this.seg(t, i)
              }, (t: string, i: number) => `sg-${i}-${t}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .margin({ bottom: this.gut() })

          if (this.tab === 0) {
            ForEach(this.notes, (n: PatchNote) => {
              Column() {
                this.noteCard(n)
              }
              .width('100%')
              .margin({ bottom: this.gut() })
            }, (n: PatchNote, i: number) => `n-${i}-${n.id ?? ''}`)
          }

          if (this.tab === 1) {
            this.changeList(this.heroVMs(), '本次版本暂无英雄改动')
          }
          if (this.tab === 2) {
            this.changeList(this.itemVMs(), '本次版本暂无装备改动')
          }
          if (this.tab === 3) {
            this.changeList(this.runeVMs(), '本次版本暂无铭文改动')
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
      }

      if (this.curNote !== null) {
        Column() {
          this.detailNote()
        }
        .width('100%')
        .height('100%')
        .padding({
          top: this.headH + 8,
          bottom: this.bottomGap(),
          left: this.pad(),
          right: this.pad(),
        })
      }

      Column() {
        TopBar({
          title: '版本动态',
          status: this.statusText(),
          live: this.online,
          loading: this.loading,
          onRefresh: () => {
            this.refresh();
          }
        })

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
    .width(this.maxW() > 0 ? `${this.maxW()}vp` : '100%')
    .height('100%')
    .backgroundColor(Ui.BG)
  }
}
