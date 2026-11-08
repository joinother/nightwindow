/**
 * 压力表风格的评分表盘（双指针 + 彩虹弧带）
 * 黑针 = 今晚评分；红针 = 昨晚评分（对照用）
 */
@ComponentV2
export struct ScoreGauge {
  @Param score: number = 0;
  @Param refScore: number = 0;
  @Param gaugeSize: number = 78;
  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  @Monitor('score', 'refScore', 'gaugeSize')
  onValueChange(): void {
    this.draw();
  }

  build() {
    Canvas(this.ctx)
      .width(this.gaugeSize)
      .height(this.gaugeSize)

      .onReady(() => {
        this.draw();
      })
  }

  /** 评分 0..100 映射到表盘 135° 起、顺时针 270° */
  private angleFor(v: number): number {
    const t: number = Math.max(0, Math.min(100, v)) / 100;
    return (135 + t * 270) * Math.PI / 180;
  }

  private draw(): void {
    const c: CanvasRenderingContext2D = this.ctx;
    const s: number = this.gaugeSize;
    const cx: number = s / 2;
    const cy: number = s / 2;
    const R: number = s / 2 - 1;
    const startA: number = 135 * Math.PI / 180;
    const sweep: number = 270 * Math.PI / 180;

    c.clearRect(0, 0, s, s);

    // 外圈金属表圈
    const bezel: CanvasGradient = c.createLinearGradient(0, 0, s, s);
    bezel.addColorStop(0, '#F2F2F2');
    bezel.addColorStop(0.45, '#9A9A9A');
    bezel.addColorStop(0.55, '#E8E8E8');
    bezel.addColorStop(1, '#7C7C7C');
    c.beginPath();
    c.arc(cx, cy, R - 1, 0, Math.PI * 2);
    c.lineWidth = 2.5;
    c.strokeStyle = bezel;
    c.stroke();

    // 表盘面
    const face: CanvasGradient = c.createLinearGradient(0, 0, 0, s);
    face.addColorStop(0, '#FBFAF7');
    face.addColorStop(1, '#E9E6DF');
    c.beginPath();
    c.arc(cx, cy, R - 3, 0, Math.PI * 2);
    c.fillStyle = face;
    c.fill();

    // 彩虹弧带：绿 → 黄 → 橙 → 红
    const bandR: number = R * 0.74;
    const zones: number[] = [0, 25, 50, 75, 100];
    const zoneColors: string[] = ['#2FA84F', '#D9B62B', '#E8892B', '#D8432E'];
    for (let i = 0; i < 4; i++) {
      c.beginPath();
      c.arc(cx, cy, bandR, this.angleFor(zones[i]), this.angleFor(zones[i + 1]));
      c.lineWidth = R * 0.11;
      c.strokeStyle = zoneColors[i];
      c.stroke();
    }

    // 刻度与数字
    c.lineWidth = 1;
    for (let k = 0; k <= 20; k++) {
      const v: number = k * 5;
      const a: number = this.angleFor(v);
      const major: boolean = (k % 4 === 0);
      const r1: number = R * 0.94;
      const r2: number = R * (major ? 0.84 : 0.88);
      c.beginPath();
      c.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1);
      c.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2);
      c.strokeStyle = major ? '#2B2B2B' : '#8A8A8A';
      c.lineWidth = major ? 1.2 : 0.7;
      c.stroke();

      if (major) {
        const rt: number = R * 0.60;
        c.font = '8vp sans-serif';
        c.fillStyle = '#3A3A3A';
        c.textAlign = 'center';
        c.textBaseline = 'middle';
        c.fillText(v.toString(), cx + Math.cos(a) * rt, cy + Math.sin(a) * rt);
      }
    }

    // 红针（昨晚）：短、细
    const aRef: number = this.angleFor(this.refScore);
    c.beginPath();
    c.moveTo(cx - Math.cos(aRef) * R * 0.14, cy - Math.sin(aRef) * R * 0.14);
    c.lineTo(cx + Math.cos(aRef) * R * 0.52, cy + Math.sin(aRef) * R * 0.52);
    c.lineWidth = 1.6;
    c.strokeStyle = '#E0413A';
    c.lineCap = 'round';
    c.stroke();

    // 黑针（今晚）：长、粗
    const aCur: number = this.angleFor(this.score);
    c.beginPath();
    c.moveTo(cx - Math.cos(aCur) * R * 0.20, cy - Math.sin(aCur) * R * 0.20);
    c.lineTo(cx + Math.cos(aCur) * R * 0.68, cy + Math.sin(aCur) * R * 0.68);
    c.lineWidth = 2.4;
    c.strokeStyle = '#1A1A1A';
    c.lineCap = 'round';
    c.stroke();

    // 中心轴帽
    c.beginPath();
    c.arc(cx, cy, R * 0.14, 0, Math.PI * 2);
    const hub: CanvasGradient = c.createLinearGradient(cx - 6, cy - 6, cx + 6, cy + 6);
    hub.addColorStop(0, '#E8C878');
    hub.addColorStop(1, '#9C7B34');
    c.fillStyle = hub;
    c.fill();
    c.beginPath();
    c.arc(cx, cy, R * 0.05, 0, Math.PI * 2);
    c.fillStyle = '#5C4718';
    c.fill();
  }
}
