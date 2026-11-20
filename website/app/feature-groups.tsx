import {
  Brain,
  CalendarCheck,
  LayoutGrid,
  MessageSquareText,
  Mic,
  ShieldCheck,
  Smartphone,
  Timer,
} from "lucide-react"

const featureGroups = [
  {
    id: "iphone-features",
    title: "iPhone 版",
    summary: "Mac 上的计划与专注，也能随身接着用。",
    icon: Smartphone,
    features: [
      {
        icon: Smartphone,
        number: "05",
        title: "安排在设备间自然衔接",
        text: "日程、收集箱与目标通过 iCloud 在 Mac 和 iPhone 间同步，换台设备也能接着安排。",
      },
      {
        icon: Timer,
        number: "06",
        title: "抬手就能看到专注进度",
        text: "开始专注后，倒计时会显示在锁屏与灵动岛，不必解锁也能掌握剩余时间。",
      },
      {
        icon: LayoutGrid,
        number: "07",
        title: "主屏上就能管理今天",
        text: "用小组件查看当天安排，直接勾选完成，或开启下一段专注。",
      },
      {
        icon: Mic,
        number: "08",
        title: "灵感说出口，就先收好了",
        text: "通过 Siri 或按住麦克风口述，把临时想法快速放进收集箱，稍后再整理。",
      },
    ],
  },
  {
    id: "secretary-features",
    title: "私人日程秘书",
    summary: "把想法交给它整理，日程怎么变始终由你决定。",
    icon: Brain,
    features: [
      {
        icon: MessageSquareText,
        number: "09",
        title: "把零散描述变成清晰任务",
        text: "说出或贴上想法，秘书会整理重点、时长、优先级和期限；复杂任务还能拆成小步骤。",
      },
      {
        icon: CalendarCheck,
        number: "10",
        title: "给重要任务找个好时段",
        text: "结合会议与空档推荐合适时间，把重要的事排进精力更好的时段；确认后才会写入日程。",
      },
      {
        icon: ShieldCheck,
        number: "11",
        title: "计划有变化，也能及时调整",
        text: "专注被打断、延长或取消后，可顺延后续安排；日程太满或临近期限时，也会提醒并给出建议。",
      },
      {
        icon: Brain,
        number: "12",
        title: "慢慢熟悉你的节奏",
        text: "逐步校准任务估时，发现固定安排与高效时段；每天整理重点，也为晚间复盘留出时间。",
      },
    ],
    note: "AI 解析需要自行配置 Claude API Key；不配置时，排期、重排、提醒和复盘仍可使用。AI 功能也可以随时关闭。",
  },
]

export function FeatureGroups() {
  return (
    <div className="feature-roadmap">
      {featureGroups.map(({ id, title, summary, icon: GroupIcon, features, note }) => (
        <section className="feature-group" aria-labelledby={id} key={id}>
          <div className="feature-group-heading">
            <span className="feature-group-symbol" aria-hidden="true">
              <GroupIcon size={20} strokeWidth={1.55} />
            </span>
            <div className="feature-group-title">
              <h3 id={id}>{title}</h3>
              <p>{summary}</p>
            </div>
            <span className="feature-status">
              <span className="feature-status-dot" aria-hidden="true" />
              即将推出
            </span>
          </div>
          <div className="feature-grid feature-group-grid">
            {features.map(({ icon: Icon, number, title: featureTitle, text }) => (
              <article className="feature-card" key={number}>
                <div className="feature-top">
                  <span className="feature-icon"><Icon size={19} strokeWidth={1.55} /></span>
                  <span>{number}</span>
                </div>
                <h4>{featureTitle}</h4>
                <p>{text}</p>
              </article>
            ))}
          </div>
          {note ? <p className="feature-group-note">{note}</p> : null}
        </section>
      ))}
    </div>
  )
}
