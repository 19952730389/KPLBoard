/* 图标组件：内置 SVG 资源渲染
 * ---------------------------------------------------------------------------
 * 旧实现用 Shape + Path + viewPort 画几何图标，真机上 viewPort 缩放不可靠
 * （路径几何按物理像素解释，24 单位路径在高分屏上只渲染出 ~8vp，观感极小）。
 *
 * 新实现：resources/base/media/ic_*.svg（24×24 视口，单色 fill），
 * Image 加载后用 .fillColor() 官方能力换色，宽高即最终渲染尺寸，
 * 任意分辨率下都严格按 px（vp）大小显示，深浅色随 Theme 正常跟随。
 *
 * 用法：AppIcon({ name: 'board', px: 24, color: Ui.GOLD })
 * name 取值见 Ui.ets 的 ICON_* 常量（board/tier/player/hero/item/rune/patch/
 * refresh/moon/sun/auto）。
 */
@Component
export struct AppIcon {
  /** 图标名（对应 media 下的 ic_<name>.svg） */
  @Prop name: string = 'board';
  /** 渲染尺寸（vp），SVG 24×24 视口等比缩放 */
  @Prop px: number = 22;
  /** 着色（fillColor 替换 SVG 填充色） */
  @Prop color: string = '#ffffff';

  /** build() 内不能写复杂逻辑，资源解析统一走成员方法 */
  private res(): Resource {
    if (this.name === 'tier') {
      return $r('app.media.ic_tier');
    }
    if (this.name === 'player') {
      return $r('app.media.ic_player');
    }
    if (this.name === 'hero') {
      return $r('app.media.ic_hero');
    }
    if (this.name === 'item') {
      return $r('app.media.ic_item');
    }
    if (this.name === 'rune') {
      return $r('app.media.ic_rune');
    }
    if (this.name === 'patch') {
      return $r('app.media.ic_patch');
    }
    if (this.name === 'refresh') {
      return $r('app.media.ic_refresh');
    }
    if (this.name === 'moon') {
      return $r('app.media.ic_moon');
    }
    if (this.name === 'sun') {
      return $r('app.media.ic_sun');
    }
    if (this.name === 'auto') {
      return $r('app.media.ic_auto');
    }
    return $r('app.media.ic_board');
  }

  build() {
    Image(this.res())
      .width(this.px)
      .height(this.px)
      .fillColor(this.color)
      .draggable(false)
      .interpolation(ImageInterpolation.High)
  }
}
