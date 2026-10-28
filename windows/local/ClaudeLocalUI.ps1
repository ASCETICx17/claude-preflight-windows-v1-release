param([switch]$ValidateOnly,[string]$PreviewImagePath,[ValidateSet('Settings','Leaks','Quality')][string]$PreviewPage='Settings')
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot '..\direct\RepairLifecycle.ps1')
. (Join-Path $PSScriptRoot '..\direct\TunLocation.ps1')
. (Join-Path $PSScriptRoot 'NetworkRequests.ps1')
. (Join-Path $PSScriptRoot 'LeakChecks.ps1')
. (Join-Path $PSScriptRoot 'IpQuality.ps1')
$script:corePath=Join-Path $PSScriptRoot 'ClaudeLocalCore.ps1'
$script:worker=$null
$script:pendingAction='Check'
$script:repairAvailable=$false
$script:dirty=$false
$script:hardDirty=$false
$script:populating=$false
$script:renderPreview=[bool]$PreviewImagePath
[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Claude Preflight · v1"
 Width="1080" Height="850" MinWidth="960" MinHeight="740" WindowStartupLocation="CenterScreen" WindowState="Maximized"
 Background="#0D131E" Foreground="#EAF0F8" FontFamily="Microsoft YaHei UI" FontSize="13">
 <Window.Resources>
  <Style TargetType="Button">
   <Setter Property="Background" Value="#253349"/><Setter Property="Foreground" Value="#EAF0F8"/>
   <Setter Property="Padding" Value="18,11"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Surface" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.8"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.35"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TextBox">
   <Setter Property="Background" Value="#0F1928"/><Setter Property="Foreground" Value="#F1F5FA"/>
   <Setter Property="Padding" Value="9,4"/><Setter Property="Height" Value="42"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="CaretBrush" Value="#73DFCA"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
    <Border x:Name="InputBorder" Background="{TemplateBinding Background}" BorderBrush="#34445A" BorderThickness="1" CornerRadius="6"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="InputBorder" Property="BorderBrush" Value="#73DFCA"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ComboBox">
   <Setter Property="Background" Value="#0F1928"/><Setter Property="Foreground" Value="#EAF0F8"/>
   <Setter Property="MaxDropDownHeight" Value="320"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
    <Grid>
     <ToggleButton Focusable="False" IsChecked="{Binding IsDropDownOpen,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}">
      <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="#0F1928" BorderBrush="#34445A" BorderThickness="1" CornerRadius="6"><TextBlock Text="⌄" HorizontalAlignment="Right" Margin="0,9,12,9" Foreground="#93A6BF"/></Border></ControlTemplate></ToggleButton.Template>
     </ToggleButton>
     <ContentPresenter Margin="10,10,28,10" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" IsHitTestVisible="False"/>
     <Popup Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False">
      <Border Background="#172335" BorderBrush="#34445A" BorderThickness="1" MinWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}"><ScrollViewer MaxHeight="320"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer></Border>
     </Popup>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="#EAF0F8"/><Setter Property="Padding" Value="10,9"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem"><Border x:Name="ItemSurface" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="#2A3B51"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Label" TargetType="TextBlock"><Setter Property="Foreground" Value="#B7C6D9"/><Setter Property="Margin" Value="0,0,0,8"/></Style>
  <Style x:Key="ManualCard" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
   <Setter Property="Background" Value="#172232"/><Setter Property="Padding" Value="18"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="CardSurface" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CardSurface" Property="Opacity" Value="0.8"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Hint" TargetType="TextBlock"><Setter Property="Foreground" Value="#879AB3"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Margin" Value="0,8,0,0"/></Style>
 </Window.Resources>
 <Grid Margin="30,24" Background="#0D131E">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Grid Margin="0,0,0,23">
   <StackPanel><StackPanel Orientation="Horizontal"><TextBlock Text="Claude Preflight" FontSize="25" FontWeight="SemiBold"/><Border Background="#173C39" CornerRadius="4" Padding="8,3" Margin="12,4,0,0" VerticalAlignment="Top"><TextBlock Text="V1" Foreground="#83E4CF" FontSize="10" FontWeight="Bold"/></Border></StackPanel><TextBlock Text="检查连接，再开始工作。" Foreground="#93A6BF" Margin="0,8,0,0"/></StackPanel>
   <Border HorizontalAlignment="Right" VerticalAlignment="Top" BorderBrush="#304154" BorderThickness="1" CornerRadius="6" Padding="12,8"><TextBlock Text="WINDOWS  /  LOCAL" FontSize="10" Foreground="#93A6BF"/></Border>
  </Grid>
  <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,16">
   <Button x:Name="DashboardButton" Content="连接检查" Margin="0,0,8,0"/><Button x:Name="SettingsButton" Content="个人配置" Background="#22675C" Margin="0,0,8,0"/><Button x:Name="LeaksButton" Content="DNS / WebRTC" Margin="0,0,8,0"/><Button x:Name="QualityButton" Content="IP 质量"/>
   <TextBlock Text="填写 → 保存 → 检查 → 启动" Foreground="#879AB3" VerticalAlignment="Center" Margin="18,0,0,0"/>
  </StackPanel>
  <Border Grid.Row="2" Background="#182535" CornerRadius="8" Padding="16,13" Margin="0,0,0,18"><TextBlock x:Name="StateText" Text="首次使用：请填写个人配置并保存。" TextWrapping="Wrap" Foreground="#E8B95F"/></Border>
  <Grid Grid.Row="3">
   <Grid x:Name="DashboardPanel" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsControl x:Name="ChecksList"><ItemsControl.ItemTemplate><DataTemplate>
     <Border Background="#172232" CornerRadius="7" Padding="14,12" Margin="0,0,0,8"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="{Binding Icon}" Foreground="{Binding Color}" FontSize="18"/><StackPanel Grid.Column="1"><TextBlock Text="{Binding Name}" FontWeight="SemiBold"/><TextBlock Text="{Binding Detail}" Foreground="#A7B8CC" TextWrapping="Wrap" Margin="0,5,0,0" FontSize="12"/></StackPanel>
     </Grid></Border>
    </DataTemplate></ItemsControl.ItemTemplate></ItemsControl></ScrollViewer>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,14,0,0"><Button x:Name="RefreshButton" Content="重新检查" Margin="0,0,10,0"/><Button x:Name="LaunchButton" Content="检查并启动 Claude" Background="#22675C" IsEnabled="False" Margin="0,0,10,0"/><Button x:Name="RepairButton" Content="更新保护规则" IsEnabled="False"/></StackPanel>
   </Grid>
   <Grid x:Name="SettingsPanel">
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid x:Name="SettingsForm">
     <Grid.ColumnDefinitions><ColumnDefinition Width="1.12*"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
     <StackPanel><Border Background="#172232" CornerRadius="9" Padding="20"><StackPanel>
      <TextBlock Text="01  代理与出口" FontSize="17" FontWeight="SemiBold"/><TextBlock Text="只接受你填写的完整出口；不会自动学习新 IP。" Style="{StaticResource Hint}" Margin="0,8,0,19"/>
      <TextBlock Text="本机 HTTP 代理" Style="{StaticResource Label}"/><TextBox x:Name="ProxyBox" ToolTip="例如 http://127.0.0.1:端口"/>
      <TextBlock Text="已预填本机地址，请在冒号后补端口。v2rayN：参数设置 → Core：基础设置 → 本地混合监听端口，复制该数字；不是节点服务器端口。" Style="{StaticResource Hint}"/>
      <Grid Margin="0,18,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="1.2*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
       <StackPanel><TextBlock Text="固定出口 IPv4" Style="{StaticResource Label}"/><TextBox x:Name="IpBox"/><Button x:Name="QualityFromSettingsButton" Content="可选：测试这个 IP 的质量 ↗" Padding="6,7" Margin="0,6,0,0"/></StackPanel>
       <StackPanel Grid.Column="2"><TextBlock Text="出口国家 / 地区代码" Style="{StaticResource Label}"/><TextBox x:Name="CountryBox" MaxLength="2" CharacterCasing="Upper" ToolTip="ISO 两字母代码，例如 US、SG、TW"/></StackPanel>
      </Grid>
      <TextBlock Text="v2rayN 配置 / 数据目录" Style="{StaticResource Label}" Margin="0,18,0,8"/>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="ProxyRootBox"/><Button Grid.Column="1" x:Name="BrowseButton" Content="浏览" Padding="12,10" Margin="8,0,0,0"/><Button Grid.Column="2" x:Name="DetectProxyButton" Content="读取运行目录" Padding="10,10" Margin="8,0,0,0"/></Grid>
      <TextBlock Text="选择包含 guiConfigs 的数据目录，不是 bin/sing_box 内核目录。兼容新版 binConfigs/configPre.json 和旧版 guiConfigs/configPre.json。" Style="{StaticResource Hint}"/>
      <TextBlock Text="已有 TUN 网卡名称" Style="{StaticResource Label}" Margin="0,18,0,8"/><TextBox x:Name="TunBox"/>
      <TextBlock Text="仅核对已有 TUN，不创建第二个隧道。" Style="{StaticResource Hint}"/>
      <TextBlock Text="DNS 比较基线（可选）· 有检测结果就自动填入首次草稿" Style="{StaticResource Label}" Margin="0,18,0,8"/><TextBox x:Name="DnsAllowBox" Height="76" MaxLength="4096" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
      <TextBlock Text="不用自己找地址，也不要填代理出口。检测取得有效 DNS 结果后，空白处会自动填入，即使 HTTP 出口不匹配也可填入；点击保存只用于以后比较地址是否变化，不代表验证了安全性。" Style="{StaticResource Hint}"/>
      <TextBlock Text="这里记录的是本轮实际使用的 DNS 解析器出口，不会更改系统 DNS，也不是给服务器授予权限。已有基线不会自动扩大；地址轮换时，可在检测页点击“填入本次 DNS 地址”重新核对。" Style="{StaticResource Hint}"/>
      <TextBlock x:Name="DnsDraftStatus" Text="还没有可采用的检测结果。" Style="{StaticResource Hint}"/>
      <TextBlock Text="留空也能启动 Claude；本项只作提醒。最多记录 32 个地址，IPv4 / IPv6 都可能是远端解析器服务器；这里出现 IPv6 不代表你的电脑通过 IPv6 直连。检测超时没有地址时不自动编造或填入公共 DNS。" Style="{StaticResource Hint}"/>
     </StackPanel></Border></StackPanel>
     <StackPanel Grid.Column="2"><Border Background="#172232" CornerRadius="9" Padding="20"><StackPanel>
      <TextBlock Text="02  时区与语言" FontSize="17" FontWeight="SemiBold"/><TextBlock Text="时区可与出口地区不同；配对规则由本项目设定。" Style="{StaticResource Hint}" Margin="0,8,0,18"/>
      <TextBlock Text="目标 Windows 时区" Style="{StaticResource Label}"/>
      <ComboBox x:Name="ZoneCombo" IsTextSearchEnabled="True" TextSearch.TextPath="Label">
       <ComboBox.ItemContainerStyle><Style TargetType="ComboBoxItem" BasedOn="{StaticResource {x:Type ComboBoxItem}}"><Setter Property="IsEnabled" Value="{Binding Selectable}"/><Setter Property="Foreground" Value="{Binding Color}"/></Style></ComboBox.ItemContainerStyle>
       <ComboBox.ItemTemplate><DataTemplate><TextBlock Text="{Binding Label}" Foreground="{Binding Color}" TextTrimming="CharacterEllipsis"/></DataTemplate></ComboBox.ItemTemplate>
      </ComboBox>
      <TextBlock x:Name="ZoneRecommendationText" Text="推荐新加坡、台北、美国。" Style="{StaticResource Hint}"/>
      <TextBlock Text="区域格式 / Claude 启动语言" Style="{StaticResource Label}" Margin="0,17,0,8"/><ComboBox x:Name="LanguageCombo" IsTextSearchEnabled="True" TextSearch.TextPath="Label"><ComboBox.ItemTemplate><DataTemplate><TextBlock Text="{Binding Label}"/></DataTemplate></ComboBox.ItemTemplate></ComboBox>
      <TextBlock Text="同一项设置派生启动语言，无须修改 Windows 显示语言。" Style="{StaticResource Hint}"/>
      <Border Background="#111B2B" CornerRadius="6" Padding="12" Margin="0,17,0,0"><StackPanel><TextBlock x:Name="LocaleStatus" Text="× 拒绝连接：请选择时区和地区语言。" Foreground="#F18C8F" TextWrapping="Wrap"/><TextBlock x:Name="SystemLocaleText" Style="{StaticResource Hint}"/></StackPanel></Border>
      <WrapPanel Margin="0,12,0,0"><Button x:Name="ReadSystemButton" Content="读取系统地区" Padding="11,8" Margin="0,0,8,7"/><Button x:Name="TimeSettingsButton" Content="Windows 时区设置 ↗" Padding="11,8" Margin="0,0,8,7"/><Button x:Name="RegionSettingsButton" Content="区域格式设置 ↗" Padding="11,8" Margin="0,0,0,7"/></WrapPanel>
     </StackPanel></Border></StackPanel>
    </Grid></ScrollViewer>
    <Grid Grid.Row="1" Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel VerticalAlignment="Center" Margin="0,0,16,0"><TextBlock x:Name="SaveStatus" Text="个人信息只保存到一个本地文件，发布包排除该文件。" TextWrapping="Wrap" Foreground="#A7B8CC"/><TextBlock Text="windows/local/settings.json  ·  不生成配置副本或敏感清单" Foreground="#73CDBB" FontSize="11" Margin="0,5,0,0"/></StackPanel>
     <Button Grid.Column="1" x:Name="SaveButton" Content="保存配置" Background="#22675C" Padding="32,18" FontSize="17" FontWeight="SemiBold" MinWidth="220" MinHeight="64" IsEnabled="False"/>
    </Grid>
   </Grid>
   <Grid x:Name="LeaksPanel" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
    <TextBlock Text="结果只代表检测当时的网络。切换节点或 TUN 后，请重新检测；非 TUN 下测通不代表 TUN 已修复。两项只作提醒，DNS 基线可留空。" Style="{StaticResource Hint}" Margin="0,0,0,12"/>
    <TextBlock x:Name="LeakProgressText" Text="DNS / WebRTC 仅作黄色提醒，不作为启动条件。检测在后台进行，分别返回，最长约 30 秒；本机代理可用即可测量。" Foreground="#E8B95F" TextWrapping="Wrap" Margin="0,0,0,16"/>
    </StackPanel>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
     <Border Background="#172232" CornerRadius="9" Padding="20"><StackPanel>
      <TextBlock Text="DNS 解析器观测" FontSize="19" FontWeight="SemiBold"/>
      <TextBlock x:Name="DnsResultText" Text="尚未检测" Foreground="#879AB3" TextWrapping="Wrap" Margin="0,18,0,14"/>
      <TextBlock Text="实际观测到的解析器出口 IP" Style="{StaticResource Label}"/>
      <TextBox x:Name="DnsObservedBox" IsReadOnly="True" Height="112" VerticalScrollBarVisibility="Auto"/>
      <TextBlock x:Name="DnsScopeText" Style="{StaticResource Hint}"/>
      <TextBlock Text="这里是 DNS 服务器的出口，可以有多个 IPv4 / IPv6；不是你的网卡地址。取得结果后自动填入首次比较草稿；基线可留空，不影响启动。本项测量 Windows DNS，浏览器自己的安全 DNS / DoH 可能使用另一条路径。" Style="{StaticResource Hint}" Margin="0,18,0,0"/>
     </StackPanel></Border>
     <Border Grid.Column="2" Background="#172232" CornerRadius="9" Padding="20"><StackPanel>
      <TextBlock Text="浏览器 WebRTC / ICE" FontSize="19" FontWeight="SemiBold"/>
      <TextBlock x:Name="RtcResultText" Text="尚未检测" Foreground="#879AB3" TextWrapping="Wrap" Margin="0,18,0,14"/>
      <TextBlock Text="可见的公网候选地址" Style="{StaticResource Label}"/>
      <TextBox x:Name="RtcObservedBox" IsReadOnly="True" Height="112" VerticalScrollBarVisibility="Auto"/>
      <TextBlock x:Name="RtcScopeText" Style="{StaticResource Hint}"/>
      <TextBlock Text="临时 Edge 向两处 STUN 查询 UDP 出口。出现其他公网地址需核实来源；没有收到回复只说明本轮没观察到暴露，不能证明所有路径安全。国外地址也可能是代理中转或另一条出口，单看国家无法判定。端口变化、内网、本地链路和中继地址不算额外公网出口。" Style="{StaticResource Hint}" Margin="0,18,0,0"/>
     </StackPanel></Border>
    </Grid></ScrollViewer>
    <WrapPanel Grid.Row="2" Margin="0,16,0,0">
     <Button x:Name="LeakRunButton" Content="检测 DNS / WebRTC" Background="#22675C" Margin="0,0,10,6"/>
     <Button x:Name="EditDnsButton" Content="查看 DNS 比较基线" Margin="0,0,10,6"/>
     <Button x:Name="FillDnsButton" Content="填入本次 DNS 地址" IsEnabled="False" Margin="0,0,10,6"/>
     <Button x:Name="DnsSourceButton" Content="DNS 检测来源 ↗" Margin="0,0,10,6"/>
     <Button x:Name="RtcSourceButton" Content="WebRTC 复核网页 ↗" Margin="0,0,0,6"/>
    </WrapPanel>
   </Grid>
   <Grid x:Name="QualityPanel" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Text="风险评分：越低越好。输入任意公网 IP / 报告链接，可测试机房 IP，不必改固定出口。自动请求只发给 IPQuery，经已保存代理；IPinfo.CV 改为网页查看。不保存查询记录，不用于启动放行。" Style="{StaticResource Hint}" Margin="0,0,0,16"/>
    <Grid Grid.Row="1" Margin="0,0,0,18"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBox x:Name="QualityTargetBox" ToolTip="输入完整公网 IP，或带有 IP 的报告链接；只提取 IP，不访问粘贴的地址。" Margin="0,0,12,0"/>
     <Button x:Name="QualityRunButton" Grid.Column="1" Content="查询风险评分" Background="#22675C"/>
    </Grid>
    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
     <Border Background="#172232" CornerRadius="9" Padding="20"><StackPanel>
      <TextBlock Text="IPQuery · 风险评分" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock x:Name="IpQueryScoreText" Text="—" Foreground="#A7B8CC" FontSize="34" Margin="0,10,0,4"/>
      <TextBlock Text="0–100 · 越低越好，建议优先选风险分 0" Style="{StaticResource Hint}"/>
      <TextBlock x:Name="IpQueryDetailText" Text="尚未查询" TextWrapping="Wrap" Margin="0,10,0,8"/>
      <TextBlock x:Name="IpQuerySignalsText" Style="{StaticResource Hint}"/>
      <TextBlock x:Name="IpQueryTimeText" Style="{StaticResource Hint}"/>
      <Button x:Name="IpQuerySourceButton" Content="原网站 ipquery.io ↗" Margin="0,8,0,0" Padding="12,8"/>
     </StackPanel></Border>
     <UniformGrid Grid.Column="2" x:Name="ManualSitesGrid" Rows="2" Columns="2">
      <Button x:Name="CvSourceButton" Style="{StaticResource ManualCard}" Margin="0,0,8,8"><StackPanel>
       <TextBlock Text="IPinfo.CV" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
       <TextBlock Text="Claude 专项网页检测；请核对浏览器当前出口和分数说明。" Style="{StaticResource Hint}"/>
       <TextBlock Text="打开网页 ↗" Foreground="#73DFCA" Margin="0,14,0,0"/>
      </StackPanel></Button>
      <Button x:Name="CoffeeSourceButton" Style="{StaticResource ManualCard}" Margin="8,0,0,8"><StackPanel>
       <TextBlock Text="Claude 信任评分" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
       <TextBlock Text="Net.Coffee · 信任分越高越好，检测浏览器当前出口。" Style="{StaticResource Hint}"/>
       <TextBlock Text="打开网页 ↗" Foreground="#73DFCA" Margin="0,14,0,0"/>
      </StackPanel></Button>
      <Button x:Name="RiskSourceButton" Style="{StaticResource ManualCard}" Margin="0,8,8,0"><StackPanel>
       <TextBlock Text="IP 纯净度检测" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
       <TextBlock Text="IPRisk · 纯净度越高越好，可在网页输入待查 IP。" Style="{StaticResource Hint}"/>
       <TextBlock Text="打开网页 ↗" Foreground="#73DFCA" Margin="0,14,0,0"/>
      </StackPanel></Button>
      <Button x:Name="ScamSourceButton" Style="{StaticResource ManualCard}" Margin="8,8,0,0"><StackPanel>
       <TextBlock Text="Scamalytics 欺诈评分" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
       <TextBlock Text="越低越好；自动附上已保存的固定 IP。" Style="{StaticResource Hint}"/>
       <TextBlock Text="打开网页 ↗" Foreground="#73DFCA" Margin="0,14,0,0"/>
      </StackPanel></Button>
     </UniformGrid>
    </Grid>
   </Grid>
  </Grid>
  <Border Grid.Row="4" BorderBrush="#263448" BorderThickness="0,1,0,0" Margin="0,20,0,0" Padding="0,14,0,0"><TextBlock Text="保护边界：启动前检查；专用 Windows 程序规则。" TextWrapping="Wrap" FontSize="11" Foreground="#879AB3"/></Border>
 </Grid>
</Window>
'@
$reader=New-Object System.Xml.XmlNodeReader $xaml
$script:window=[Windows.Markup.XamlReader]::Load($reader)
$script:ui=@{}
foreach($name in @('StateText','DashboardButton','SettingsButton','DashboardPanel','SettingsPanel','SettingsForm','ChecksList','RefreshButton','LaunchButton','RepairButton','ProxyBox','IpBox','CountryBox','ProxyRootBox','TunBox','DnsAllowBox','ZoneCombo','LanguageCombo','LocaleStatus','SystemLocaleText','SaveStatus','SaveButton','BrowseButton','ReadSystemButton','TimeSettingsButton','RegionSettingsButton','LeaksButton','LeaksPanel','LeakRunButton','EditDnsButton','DnsSourceButton','RtcSourceButton','DnsResultText','DnsObservedBox','DnsScopeText','RtcResultText','RtcObservedBox','RtcScopeText')) {
    $script:ui[$name]=$script:window.FindName($name)
    if(-not $script:ui[$name]){throw ('界面控件缺失：'+$name)}
}
$script:zones=@(Get-CSLocaleCatalog|Sort-Object @{Expression='Recommended';Descending=$true},Label)
foreach($name in @('DetectProxyButton','ZoneRecommendationText','ManualSitesGrid','QualityButton','QualityFromSettingsButton','QualityPanel','QualityTargetBox','QualityRunButton','IpQueryScoreText','IpQueryDetailText','IpQuerySignalsText','IpQueryTimeText','IpQuerySourceButton','CvSourceButton','CoffeeSourceButton','RiskSourceButton','ScamSourceButton')){
    $script:ui[$name]=$script:window.FindName($name)
    if(-not $script:ui[$name]){throw ('界面控件缺失：'+$name)}
}
$script:ui.FillDnsButton=$script:window.FindName('FillDnsButton')
$script:ui.DnsDraftStatus=$script:window.FindName('DnsDraftStatus')
$script:ui.LeakProgressText=$script:window.FindName('LeakProgressText')
$script:ui.ZoneCombo.ItemsSource=$script:zones
function Show-CSPage([bool]$Settings){
    $script:ui.QualityPanel.Visibility='Collapsed';$script:ui.QualityButton.Background='#253349'
    $script:ui.LeaksPanel.Visibility='Collapsed';$script:ui.LeaksButton.Background='#253349'
    $script:ui.SettingsPanel.Visibility=if($Settings){'Visible'}else{'Collapsed'}
    $script:ui.DashboardPanel.Visibility=if($Settings){'Collapsed'}else{'Visible'}
    $script:ui.SettingsButton.Background=if($Settings){'#22675C'}else{'#253349'}
    $script:ui.DashboardButton.Background=if($Settings){'#253349'}else{'#22675C'}
}
function Show-CSLeaks {
    $script:ui.QualityPanel.Visibility='Collapsed';$script:ui.QualityButton.Background='#253349'
    $script:ui.SettingsPanel.Visibility='Collapsed';$script:ui.DashboardPanel.Visibility='Collapsed';$script:ui.LeaksPanel.Visibility='Visible'
    $script:ui.SettingsButton.Background='#253349';$script:ui.DashboardButton.Background='#253349';$script:ui.LeaksButton.Background='#22675C'
}
function Show-CSQuality([switch]$FromSettings) {
    $script:ui.SettingsPanel.Visibility='Collapsed';$script:ui.DashboardPanel.Visibility='Collapsed';$script:ui.LeaksPanel.Visibility='Collapsed';$script:ui.QualityPanel.Visibility='Visible'
    foreach($name in @('SettingsButton','DashboardButton','LeaksButton')){$script:ui[$name].Background='#253349'}
    $script:ui.QualityButton.Background='#22675C'
    if($FromSettings -or -not $script:ui.QualityTargetBox.Text){$script:ui.QualityTargetBox.Text=$script:ui.IpBox.Text.Trim()}
}
function Format-CSCheckTime([string]$Value) {
    $time=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse($Value,[ref]$time)){return $time.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')}
    return '未提供'
}
function Open-CSQualitySite([string]$Site) {
    try{
        $saved=if($Site -eq 'Scamalytics'){(Get-CSConfig).expectedEgressIP}else{''}
        Start-Process (Get-CSQualityWebLink $Site $saved)
    }catch{$script:ui.StateText.Text='请先保存完整配置，再打开带固定 IP 的报告链接。'}
}
function Set-CSQualityDisplay($Report) {
    foreach($provider in @('IPQuery')){
        $prefix='IpQuery'
        $result=if($Report){@($Report.Results|Where-Object Provider -eq $provider)|Select-Object -First 1}else{$null}
        $available=($result -and $result.State -eq 'ok' -and $null -ne $result.Score)
        $script:ui[$prefix+'ScoreText'].Text=if($available){[string]$result.Score+' / 100'}else{'—'}
        $script:ui[$prefix+'ScoreText'].Foreground=if($available -and $result.Score -eq 0){'#A7B8CC'}else{'#E8B95F'}
        $script:ui[$prefix+'DetailText'].Text=if($result){$result.Detail}else{'尚未查询'}
        $script:ui[$prefix+'SignalsText'].Text=if($available){'属性：'+((@($result.Signals)|ForEach-Object {switch($_){'datacenter'{'机房 / 数据中心'}'proxy'{'代理'}'vpn'{'VPN'}'tor'{'Tor'}'mobile'{'移动网络'}default{$_}}}) -join '，')}else{''}
        $script:ui[$prefix+'TimeText'].Text=if($result){'目标：'+$Report.Target+[Environment]::NewLine+'数据时间：'+$result.DataTime+[Environment]::NewLine+'查询时间（本机）：'+(Format-CSCheckTime $result.CheckedUtc)}else{''}
    }
}
function Set-CSLeakDisplay($Diagnostics) {
    $script:lastDnsDraft=if($Diagnostics -and $Diagnostics.Dns){[pscustomobject]@{Result=$Diagnostics.Dns;Proxy=$script:ui.ProxyBox.Text.Trim();Pinned=$script:ui.IpBox.Text.Trim()}}else{$null}
    foreach($kind in @('Dns','WebRtc')){
        $prefix=if($kind -eq 'Dns'){'Dns'}else{'Rtc'}
        $result=if($Diagnostics){$Diagnostics.$kind}else{$null}
        $state=if($result){$result.State}else{'pending'}
        $script:ui[$prefix+'ResultText'].Foreground=if($state -eq 'ok'){'#73DFCA'}else{'#E8B95F'}
        $label=switch($state){'ok'{'✓ 本次未发现异常：'}'fail'{'! 异常提醒：'}'unknown'{'? 提醒：'}default{''}}
        $script:ui[$prefix+'ResultText'].Text=if($result){$label+$result.Detail}else{'尚未检测'}
        $attempted=($result -and ('Attempted' -notin $result.PSObject.Properties.Name -or $result.Attempted))
        $script:ui[$prefix+'ObservedBox'].Text=if($result -and @($result.Addresses).Count){$result.Addresses -join [Environment]::NewLine}elseif(-not $result){'尚未检测'}elseif($state -eq 'pending'){'正在等待结果，可继续使用其他功能。'}elseif(-not $attempted){'本次未执行：请查看上方具体原因'}elseif($result.EmptyReason){$result.EmptyReason}else{'本轮没有可显示的公网地址；请查看具体检测结果'}
        $script:ui[$prefix+'ScopeText'].Text=if($result){(@($result.Scope)+@($result.DiagnosticLines)+@('检查时间（本机）：'+(Format-CSCheckTime $result.CheckedUtc))) -join [Environment]::NewLine}else{''}
    }
    if($Diagnostics -and $Diagnostics.Dns){
        $dns=$Diagnostics.Dns
        if($dns.State -eq 'pending'){$script:ui.DnsDraftStatus.Text='正在等待 DNS 结果；本项可留空，不影响启动。'}
        elseif(@(Get-CSDnsDraftAddresses (Get-CSFormConfig) $dns).Count -eq 0){
            $script:ui.DnsDraftStatus.Text=if(@($dns.Addresses).Count -gt 32){'本轮地址超过 32 个，未自动填入；可选基线可留空。'}else{'本轮未取得有效解析器地址，无法自动填入；无需手填，留空不影响启动。'}
        }elseif($script:ui.DnsAllowBox.Text.Trim()){$script:ui.DnsDraftStatus.Text='已有比较基线或草稿，保留现有内容；要替换请点击“填入本次 DNS 地址”。'}
    }
    Update-CSDnsDraftButton
}
function Update-CSDnsDraftButton {
    $valid=$false
    if($script:lastDnsDraft -and -not $script:worker){
        $config=Get-CSFormConfig
        $valid=($config.proxyUrl -eq $script:lastDnsDraft.Proxy -and $config.expectedEgressIP -eq $script:lastDnsDraft.Pinned -and @(Get-CSDnsDraftAddresses $config $script:lastDnsDraft.Result).Count -gt 0)
    }
    $script:ui.FillDnsButton.IsEnabled=$valid
}
function Use-CSObservedDns([switch]$Automatic) {
    Update-CSDnsDraftButton
    if(-not $script:ui.FillDnsButton.IsEnabled){return $false}
    $config=Get-CSFormConfig
    $existing=@($config.allowedDnsResolverIPs)
    if($Automatic -and $existing.Count -gt 0 -and -not ($existing.Count -eq 1 -and $existing[0] -eq $config.expectedEgressIP)){return $false}
    $addresses=@(Get-CSDnsDraftAddresses $config $script:lastDnsDraft.Result)
    if(($existing -join ',') -eq ($addresses -join ',')){return $false}
    $script:ui.DnsAllowBox.Text=$addresses -join ', '
    Update-CSForm $true -AdvisoryOnly
    $script:ui.DnsDraftStatus.Text='已自动填入 '+$addresses.Count+' 个实测地址，尚未保存。保存仅建立地址比较基线，不代表地址已验证安全。'
    if($script:lastDnsDraft.Result.Evidence.ControlMatchesPinned -ne $true){$script:ui.DnsDraftStatus.Text+=' 本轮 HTTP 出口未匹配保存值。'}
    # Draft adoption must not overwrite a required-check failure or block launch.
    return $true
}
function Get-CSFormConfig {
    Convert-CSRuntimeConfig ([pscustomobject]@{proxyUrl=$script:ui.ProxyBox.Text.Trim();expectedEgressIP=$script:ui.IpBox.Text.Trim();requiredCountry=$script:ui.CountryBox.Text.Trim();proxyRoot=$script:ui.ProxyRootBox.Text.Trim();existingTunName=$script:ui.TunBox.Text.Trim();expectedTimeZone=[string]$script:ui.ZoneCombo.SelectedItem.Id;expectedCulture=[string]$script:ui.LanguageCombo.SelectedItem.Name;allowedDnsResolverIPs=@(($script:ui.DnsAllowBox.Text -split '[,;\s]+')|Where-Object {$_})})
}
function Set-CSLanguages([string]$Preferred,[switch]$AutoSelect){
    $items=@(Get-CSCultureChoices $script:ui.ZoneCombo.SelectedItem)
    $script:ui.LanguageCombo.ItemsSource=$items
    $script:ui.LanguageCombo.SelectedItem=$items|Where-Object Name -eq $Preferred|Select-Object -First 1
    if($AutoSelect -and -not $script:ui.LanguageCombo.SelectedItem -and $items.Count){
        if($script:ui.ZoneCombo.SelectedItem.EnforceCulturePair){$script:ui.LanguageCombo.SelectedIndex=0}
        else {
            $currentName=(Get-Culture).Name
            $script:ui.LanguageCombo.SelectedItem=$items|Where-Object Name -eq $currentName|Select-Object -First 1
        }
    }
}
function Set-CSForm($Config){
    $script:populating=$true
    try{
        $script:ui.ProxyBox.Text=if($Config.proxyUrl){$Config.proxyUrl}else{'http://127.0.0.1:'};$script:ui.IpBox.Text=$Config.expectedEgressIP
        $script:ui.CountryBox.Text=$Config.requiredCountry;$script:ui.ProxyRootBox.Text=$Config.proxyRoot
        $script:ui.TunBox.Text=$Config.existingTunName
        $script:ui.DnsAllowBox.Text=@($Config.allowedDnsResolverIPs) -join ', '
        $script:ui.ZoneCombo.SelectedItem=$script:zones|Where-Object Id -eq $Config.expectedTimeZone|Select-Object -First 1
        Set-CSLanguages $Config.expectedCulture
    }finally{$script:populating=$false}
}
function Update-CSForm([bool]$Changed=$false,[switch]$AdvisoryOnly){
    if($script:populating){return}
    if($Changed){
        $script:dirty=$true
        if(-not $AdvisoryOnly){
            $script:hardDirty=$true;$script:ui.LaunchButton.IsEnabled=$false;Stop-CSAdvisories
            Set-CSLeakDisplay $null
            $script:ui.LeakProgressText.Text='必要配置已修改，旧探针结果已失效。保存后重新检测。'
        }
    }
    $config=Get-CSFormConfig
    $issues=@(Get-CSConfigurationIssues $config)
    $script:ui.SaveButton.IsEnabled=($issues.Count -eq 0 -and $script:dirty -and -not $script:worker)
    $locale=if($script:renderPreview){[pscustomobject]@{Success=$false;Detail='演示：系统区域格式尚未与所选语言匹配。'}}else{Get-CSLocaleState $config}
    $script:ui.LocaleStatus.Text=if($locale.Success){'✓ 时区与语言匹配，仍需通过其余连接检查。'}else{'× 拒绝连接：'+$locale.Detail}
    $script:ui.LocaleStatus.Foreground=if($locale.Success){'#73DFCA'}else{'#F18C8F'}
    if($script:renderPreview){$script:ui.SystemLocaleText.Text='此图使用虚构配置，不含本机 IP、目录或账号。'}
    else{try{$script:ui.SystemLocaleText.Text='当前 Windows：'+(Get-TimeZone).DisplayName+' / '+(Get-Culture).Name}catch{$script:ui.SystemLocaleText.Text='当前系统地区读取失败。'}}
    if($script:dirty){
        if($script:hardDirty){$script:ui.StateText.Text='× 拒绝连接：必要配置尚未保存。保存后将重新检查。';$script:ui.StateText.Foreground='#E8B95F'}
        $script:ui.SaveStatus.Text=if($issues.Count){'待完善：'+($issues -join ' ')}else{'字段格式通过。保存目标配置不会自动更改系统时区或区域格式。'}
    }
    Update-CSDnsDraftButton
}
function Set-CSBusy([bool]$Busy){
    $script:ui.QualityRunButton.IsEnabled=-not $Busy;$script:ui.QualityTargetBox.IsEnabled=-not $Busy
    $script:ui.LeakRunButton.IsEnabled=(-not $Busy -and $script:advisoryTasks.Count -eq 0)
    $script:ui.RefreshButton.IsEnabled=-not $Busy;$script:ui.LaunchButton.IsEnabled=$false
    $script:ui.RepairButton.IsEnabled=(-not $Busy -and $script:repairAvailable)
    $script:ui.SettingsForm.IsEnabled=-not $Busy;$script:ui.SaveButton.IsEnabled=$false
    if(-not $Busy){Update-CSForm}
}
function Start-CSWorker([string]$Action){
    if($script:worker){return}
    if($script:hardDirty){Show-CSPage $true;Update-CSForm;return}
    try{
        if($Action -in @('LeakTest','ObserveNetwork')){$probeConfig=Get-CSConfig -AllowIncomplete;$proxyIssue=Get-CSProxyIssue $probeConfig;if($proxyIssue){throw $proxyIssue}}
        else{$probeConfig=Get-CSConfig}
    }catch{Show-CSPage $true;$script:ui.StateText.Text='请检查已保存的配置；泄露检测只要求本机代理填写正确，启动 Claude 则要求完整配置。';return}
    if($Action -in @('LeakTest','ObserveNetwork')){Start-CSAdvisories $probeConfig;return}
    $qualityTarget=''
    if($Action -eq 'QualityCheck'){
        try{$qualityTarget=Convert-CSQualityTarget $script:ui.QualityTargetBox.Text}
        catch{$script:ui.StateText.Text=$_.Exception.Message;$script:ui.StateText.Foreground='#E8B95F';return}
    }
    Set-CSBusy $true;$script:pendingAction=$Action
    if($Action -eq 'Repair'){$script:repairOperationId=[guid]::NewGuid().ToString('D')}
    if($Action -eq 'QualityCheck'){Set-CSQualityDisplay $null}else{Start-CSAdvisories $probeConfig}
    $script:ui.StateText.Foreground='#A7B8CC'
    $script:ui.StateText.Text=if($Action -eq 'Repair'){'正在请求管理员授权并更新规则…'}elseif($Action -eq 'Launch'){'正在复核必要条件，通过后启动 Claude；DNS / WebRTC 在后台继续…'}else{'正在检查代理、固定出口、TUN、地区和保护规则；DNS / WebRTC 在后台继续…'}
    if($Action -eq 'QualityCheck'){$script:ui.StateText.Text='正在经显式代理查询 IPQuery 风险评分；不会自动打开外部网页…'}
    if($Action -eq 'ObserveNetwork'){$script:ui.StateText.Text='正在并行观测当前 DNS / UDP 出口；本操作不放行 Claude…'}
    $script:workerHint=$script:ui.StateText.Text
    $script:workerClock=[Diagnostics.Stopwatch]::StartNew()
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=Join-Path $PSHOME 'powershell.exe'
        $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script:corePath+'" -Action '+$Action+' -Json'
        if($Action -eq 'Repair'){$info.Arguments+=' -RepairOperationId '+$script:repairOperationId}
        if($Action -eq 'QualityCheck'){$info.Arguments+=' -QualityTarget "'+$qualityTarget+'"'}
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $script:worker=New-Object Diagnostics.Process;$script:worker.StartInfo=$info
        [void]$script:worker.Start()
        $script:outputTask=$script:worker.StandardOutput.ReadToEndAsync();$script:errorTask=$script:worker.StandardError.ReadToEndAsync()
        $script:timer.Start()
    }catch{
        if($script:worker){$script:worker.Dispose();$script:worker=$null}
        Set-CSBusy $false;$script:ui.StateText.Text='× 拒绝连接：无法启动检查进程，请重新打开此工具。';$script:ui.StateText.Foreground='#F18C8F'
    }
}
. (Join-Path $PSScriptRoot 'LeakAdvisoryUI.ps1')
$script:timer=New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval=[TimeSpan]::FromMilliseconds(250)
$script:timer.Add_Tick({
    Update-CSAdvisories
    if(-not $script:worker -and -not $script:advisoryTasks.Count -and -not $script:advisoryRetired.Count){$script:timer.Stop();return}
    if($script:worker -and -not $script:worker.HasExited){
        if($script:pendingAction -eq 'Repair'){$script:workerHint=Get-CSRepairPhaseText (Get-CSRepairState $script:repairOperationId)}
        $script:ui.StateText.Text=$script:workerHint+' 已等待 '+[int]$script:workerClock.Elapsed.TotalSeconds+' 秒。'
        return
    }
    if(-not $script:worker -or -not $script:worker.HasExited -or -not $script:outputTask.IsCompleted -or -not $script:errorTask.IsCompleted){return}
    try{
        $result=$script:outputTask.Result|ConvertFrom-Json -ErrorAction Stop
        if(-not $result -or 'CanLaunch' -notin $result.PSObject.Properties.Name){throw '检查结果不完整。'}
        $items=@()
        foreach($row in $result.Checks){
            $icon='·';$color='#879AB3'
            switch($row.Status){'ok'{$icon='✓';$color='#73DFCA'}'warn'{$icon='!';$color='#E8B95F'}'fail'{$icon='×';$color='#F18C8F'}}
            $items+=[pscustomobject]@{Name=$row.Name;Detail=(Protect-CSMessage $row.Detail);Icon=$icon;Color=$color}
        }
        if($script:pendingAction -eq 'QualityCheck'){Set-CSQualityDisplay $result.QualityReport}
        else{$script:ui.ChecksList.ItemsSource=$items;Publish-CSAdvisories}
        $script:workerClock.Stop()
        $script:ui.StateText.Text=(Protect-CSMessage $result.Message)+'（耗时 '+[Math]::Round($script:workerClock.Elapsed.TotalSeconds,1)+' 秒）'
        $script:ui.StateText.Foreground=if($result.Success -and $result.CanLaunch){'#73DFCA'}else{'#F18C8F'}
        if($script:pendingAction -in @('QualityCheck','ObserveNetwork','LeakTest')){$script:ui.StateText.Foreground='#E8B95F'}
        $script:repairAvailable=[bool]$result.NeedsRuleRefresh
        if(-not $result.Success -and $script:pendingAction -eq 'Repair'){$script:repairAvailable=$true}
        $script:worker.Dispose();$script:worker=$null;Set-CSBusy $false
        $script:ui.LaunchButton.IsEnabled=[bool]($result.Success -and $result.CanLaunch -and $script:pendingAction -ne 'Launch' -and -not $script:hardDirty)
        if($script:pendingAction -in @('LeakTest','ObserveNetwork','Check')){[void](Use-CSObservedDns -Automatic)}
        if($result.ConfigRequired){Show-CSPage $true}
    }catch{
        if($script:worker){$script:worker.Dispose();$script:worker=$null}
        Set-CSBusy $false;$script:ui.StateText.Text='× 拒绝连接：检查返回异常，请重新检查。';$script:ui.StateText.Foreground='#F18C8F'
    }
})
$script:ui.DashboardButton.Add_Click({Show-CSPage $false})
$script:ui.SettingsButton.Add_Click({Show-CSPage $true;Update-CSForm})
$script:ui.LeaksButton.Add_Click({Show-CSLeaks})
$script:ui.QualityButton.Add_Click({Show-CSQuality})
$script:ui.QualityFromSettingsButton.Add_Click({Show-CSQuality -FromSettings})
$script:ui.QualityRunButton.Add_Click({Show-CSQuality;Start-CSWorker 'QualityCheck'})
$script:ui.IpQuerySourceButton.Add_Click({Start-Process 'https://ipquery.io/'})
$script:ui.CvSourceButton.Add_Click({Open-CSQualitySite 'IpInfoCv'})
$script:ui.CoffeeSourceButton.Add_Click({Open-CSQualitySite 'Coffee'})
$script:ui.RiskSourceButton.Add_Click({Open-CSQualitySite 'IPRisk'})
$script:ui.ScamSourceButton.Add_Click({Open-CSQualitySite 'Scamalytics'})
$script:ui.LeakRunButton.Add_Click({Show-CSLeaks;Start-CSWorker 'LeakTest'})
$script:ui.EditDnsButton.Add_Click({Show-CSPage $true;$script:ui.DnsAllowBox.BringIntoView();[void]$script:ui.DnsAllowBox.Focus()})
$script:ui.FillDnsButton.Add_Click({if(Use-CSObservedDns){Show-CSPage $true;$script:ui.DnsAllowBox.BringIntoView()}})
$script:ui.DnsSourceButton.Add_Click({Start-Process 'https://bash.ws/dnsleak'})
$script:ui.RtcSourceButton.Add_Click({Start-Process 'https://browserleaks.com/webrtc'})
$script:ui.RefreshButton.Add_Click({Start-CSWorker 'Check'})
$script:ui.LaunchButton.Add_Click({Start-CSWorker 'Launch'})
$script:ui.RepairButton.Add_Click({Start-CSWorker 'Repair'})
foreach($name in @('ProxyBox','IpBox','CountryBox','ProxyRootBox','TunBox')){$script:ui[$name].Add_TextChanged({Update-CSForm $true})}
$script:ui.DnsAllowBox.Add_TextChanged({Update-CSForm $true -AdvisoryOnly})
$script:ui.ZoneCombo.Add_SelectionChanged({
    if($script:populating){return}
    $prior=[string]$script:ui.LanguageCombo.SelectedItem.Name;$script:populating=$true
    try{Set-CSLanguages $prior -AutoSelect}finally{$script:populating=$false}
    Update-CSForm $true
})
$script:ui.LanguageCombo.Add_SelectionChanged({Update-CSForm $true})
$script:ui.BrowseButton.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description='选择包含 guiConfigs 的 v2rayN 目录';$dialog.ShowNewFolderButton=$false
    try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$script:ui.ProxyRootBox.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}
})
$script:ui.DetectProxyButton.Add_Click({
    try{
        $roots=@(Get-CSRunningV2rayRoots)
        if($roots.Count -ne 1){throw '未能唯一识别运行中的 v2rayN，请先打开正确实例或手动选择目录。'}
        $script:ui.ProxyRootBox.Text=$roots[0]
        $script:ui.SaveStatus.Text='已读取当前运行目录；请保存配置。'
    }catch{$script:ui.SaveStatus.Text=Protect-CSMessage $_.Exception.Message}
})
$script:ui.ReadSystemButton.Add_Click({
    try{
        $zone=(Get-TimeZone).Id;$culture=(Get-Culture).Name
        $target=$script:zones|Where-Object {$_.Id -eq $zone -and $_.Selectable}|Select-Object -First 1
        if(-not $target){$script:ui.SaveStatus.Text='系统时区尚未识别，请从列表手动选择。';return}
        $script:populating=$true
        try{$script:ui.ZoneCombo.SelectedItem=$target;Set-CSLanguages $culture}finally{$script:populating=$false}
        Update-CSForm $true
    }catch{$script:ui.SaveStatus.Text='无法读取系统地区，请手动选择。'}
})
$script:ui.TimeSettingsButton.Add_Click({Start-Process 'ms-settings:dateandtime'})
$script:ui.RegionSettingsButton.Add_Click({Start-Process 'ms-settings:regionformatting'})
$script:ui.SaveButton.Add_Click({
    if($script:worker){return}
    try{
        $config=Save-CSConfig (Get-CSFormConfig);Set-CSForm $config;$script:dirty=$false;$script:hardDirty=$false;Update-CSForm
        $script:ui.SaveStatus.Text='✓ 配置已保存到唯一的本地配置文件。'
        Show-CSPage $false;Start-CSWorker 'Check'
    }catch{$script:ui.SaveStatus.Text='× 保存失败：'+(Protect-CSMessage $_.Exception.Message);$script:ui.LaunchButton.IsEnabled=$false}
})
$script:window.Add_Closed({
    $script:timer.Stop()
    Close-CSAdvisories
    if($script:worker){if(-not $script:worker.HasExited){$script:worker.Kill()};$script:worker.Dispose();$script:worker=$null}
})
try{$initial=Get-CSConfig -AllowIncomplete}catch{$initial=Convert-CSRuntimeConfig (Get-CSConfigTemplate);$script:ui.SaveStatus.Text='配置格式损坏，请重新填写并保存。'}
Set-CSForm $initial;Update-CSForm;Set-CSLeakDisplay $null;Set-CSQualityDisplay $null
if($ValidateOnly){'WPF UI validation passed: controls loaded, configuration form initialized, no network or system mutation.';return}
if($PreviewImagePath){
    $fake=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\tests\public-fixture.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Set-CSForm (Convert-CSRuntimeConfig $fake);$script:dirty=$true;Update-CSForm
    $script:ui.SaveStatus.Text='演示数据 · 保存后才写入唯一的本地配置文件。';Show-CSPage $true
    if($PreviewPage -eq 'Leaks'){
        Show-CSLeaks
        $script:ui.StateText.Text='演示界面：以下为虚构结果，未执行真实网络检测。'
        Set-CSLeakDisplay ([pscustomobject]@{
            Dns=[pscustomobject]@{State='unknown';Detail='已取得解析器地址；首次比较草稿会自动填入，留空不影响启动。';Addresses=@('198.51.100.53');Scope='Windows 默认解析链 · 随机域名权威侧观测';DiagnosticLines=@('会话接口 HTTP 200；报告接口 HTTP 200，JSON 解析成功','系统 DNS 查询：6/6 完成，0 失败，0 尚未完成','观测到 1 个解析器出口；DNS 地址允许有多个，不必与代理出口相同');CheckedUtc='示例数据'}
            WebRtc=[pscustomobject]@{State='unknown';Detail='本轮未观察到公网地址暴露；未完成两处 STUN 核验，仅作黄色提醒，不阻止启动。';Addresses=@();Scope='独立临时 Edge · 浏览器 ICE';EmptyReason='本轮未收集到公网地址：没有观察到暴露，也没有验证到代理出口';DiagnosticLines=@('Cloudflare：候选收集完成；STUN 公网反射地址 0 个；错误码 701','Google：候选收集完成；STUN 公网反射地址 0 个；错误码 701','已核验固定出口的 STUN：0/2。候选收集完成不等于 STUN 请求成功');CheckedUtc='示例数据'}
        })
    }
    if($PreviewPage -eq 'Quality'){
        Show-CSQuality
        $script:ui.StateText.Text='演示界面：以下为虚构分数，未执行查询。'
        Set-CSQualityDisplay ([pscustomobject]@{Target='203.0.113.10';Results=@(
            [pscustomobject]@{Provider='IPQuery';State='ok';Score=20;Detail='识别为机房 IP。低风险分不等于住宅 IP，也不等于 Claude 信任度高。';Signals=@('datacenter');DataTime='未提供数据生成时间';CheckedUtc='2026-10-22T04:40:54Z'}
        )})
    }
    $surface=$script:window.Content
    $surface.Measure((New-Object Windows.Size(1080,810)));$surface.Arrange((New-Object Windows.Rect(0,0,1080,810)));$surface.UpdateLayout()
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(1080,810,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $background=New-Object Windows.Media.DrawingVisual
    $context=$background.RenderOpen()
    $context.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString('#0D131E'),$null,(New-Object Windows.Rect(0,0,1080,810)))
    $context.Close()
    $bitmap.Render($background)
    $bitmap.Render($surface)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($PreviewImagePath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
    'WPF preview rendered with fictional data only.';return
}
$script:window.Add_ContentRendered({if(@(Get-CSConfigurationIssues (Get-CSFormConfig)).Count -eq 0){Show-CSPage $false;Start-CSWorker 'Check'}else{Show-CSPage $true}})
[void]$script:window.ShowDialog()
