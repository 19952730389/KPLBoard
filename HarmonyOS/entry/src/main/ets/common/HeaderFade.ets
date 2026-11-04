/* 悬浮页头底部的渐隐过渡条：让模糊区下缘不再生硬（配合 PageShell 使用） */
import { Ui } from './Ui';

@Component
export struct HeaderFade {
  build() {
    Row() {}
      .width('100%')
      .height(16)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [[Ui.GLASS, 0.0], [Ui.GLASS_CLEAR, 1.0]]
      })
  }
}
