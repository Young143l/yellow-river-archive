/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { font, window } from '@kit.ArkUI';

import { SyncSelfTest } from '../service/sync/SyncSelfTest';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    // 注册思源宋体（Noto Serif SC，SIL OFL-1.1）。
    // 中文排版的高级感八成来自字体：系统无衬线体让「文化档案」读起来像工具 App，
    // 而宋体的横细竖粗与笔锋才配得上这批内容。
    // 字体是 GB2312 一级字库 + 正文用字的子集（3856 字形 / 各约 1.5MB），
    // 完整字体 14MB，全量打包没必要。
    //
    // 两处必须分开注册：SemiBold 的 name 表里 family 是「Noto Serif SC SemiBold」，
    // 与 Regular 不同族。若只注册一个 family 再靠 fontWeight 切换，
    // ArkUI 会去合成粗体，中文合成粗体会糊。
    try {
      font.registerFont({ familyName: 'Serif', familySrc: $rawfile('fonts/NotoSerifSC-Regular.ttf') });
      font.registerFont({ familyName: 'SerifBold', familySrc: $rawfile('fonts/NotoSerifSC-SemiBold.ttf') });
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'Serif fonts registered');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Font register failed: %{public}s', JSON.stringify(err));
    }

    // 同步链路自检：写入→读回→LWW 合并→分布式 KV 全链路，跑完自动清理。
    // 异步执行不阻塞 Ability 创建；结果打到日志供开发期验证，
    // 后续同步中心页会以「自检」按钮的形式复用同一实现。
    const ctx = this.context;
    SyncSelfTest.run(ctx)
      .then((report) => {
        hilog.info(DOMAIN, 'syncTest', '%{public}s', SyncSelfTest.format(report));
      })
      .catch((err: Object) => {
        hilog.error(DOMAIN, 'syncTest', 'Self test crashed: %{public}s', JSON.stringify(err));
      });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}