//+------------------------------------------------------------------+
//|                                          Smart_Money_Manager.mq5 |
//|   Risk-based sizing + market/pending orders + protection + panel |
//+------------------------------------------------------------------+
#property copyright "Smart Money Manager"
#property version   "2.20"
#property description "Advanced money management EA with a modern on-chart panel."
#property description "Market + Limit + Stop orders, chart preview lines, risk-% lot sizing,"
#property description "daily loss/profit limits, drawdown guard, loss streak lock, open-risk cap,"
#property description "trading hours / spread / news filters, break-even, trailing, partial close."

#include <Trade\Trade.mqh>

//--- enums
enum ENUM_LOCK_ACTION
  {
   LOCK_ALERT = 0,   // Alert only
   LOCK_SOFT  = 1,   // Block new orders
   LOCK_HARD  = 2    // Block + close all + delete pendings
  };

enum ENUM_NEWS_LEVEL
  {
   NEWS_OFF      = 0, // Off
   NEWS_HIGH     = 1, // High impact only
   NEWS_MED_HIGH = 2  // Medium + High impact
  };

//--- inputs
input group "=== Risk Settings ==="
input double InpRiskPercent      = 1.0;    // Risk per trade (% of balance)
input int    InpSLPoints         = 300;    // Stop Loss (points)
input double InpRR               = 2.0;    // Reward : Risk ratio (0 = no TP)
input double InpFixedLot         = 0.0;    // Fixed lot (0 = auto from risk %)

input group "=== Pending Orders ==="
input int    InpEntryDistance    = 200;    // Pending distance from price (points)
input int    InpExpiryMinutes    = 0;      // Pending expiry (minutes, 0 = GTC)

input group "=== Account Limits (0 = off) ==="
input double InpMaxDailyLossPct  = 3.0;    // Max daily loss (% of day-start balance)
input double InpMaxDailyProfitPct= 0.0;    // Daily profit target lock (%)
input double InpMaxDrawdownPct   = 10.0;   // Max equity drawdown from peak (%)
input int    InpMaxLossStreak    = 0;      // Lock after N consecutive losing closes today
input int    InpMaxTradesPerDay  = 0;      // Max trades opened per day
input int    InpMaxPositions     = 3;      // Max open positions + pending orders
input double InpMaxOpenRiskPct   = 0.0;    // Max total open risk (% of balance)
input ENUM_LOCK_ACTION InpLockAction = LOCK_SOFT; // Action when a limit is hit

input group "=== Filters ==="
input bool   InpUseHours         = false;  // Use trading hours filter
input int    InpStartHour        = 8;      // Trading start hour (server time)
input int    InpEndHour          = 20;     // Trading end hour (server time)
input int    InpMaxSpread        = 0;      // Max spread (points, 0 = off)
input ENUM_NEWS_LEVEL InpNewsLevel = NEWS_OFF; // News filter (MT5 economic calendar)
input int    InpNewsBefore       = 30;     // Block minutes before news
input int    InpNewsAfter        = 30;     // Block minutes after news

input group "=== Trade Management ==="
input bool   InpUseBE            = true;   // Auto break-even
input int    InpBETrigger        = 200;    // Break-even trigger (points of profit)
input int    InpBEOffset         = 20;     // Break-even offset (points)
input bool   InpUseTrail         = true;   // Auto trailing stop
input int    InpTrailStart       = 300;    // Trailing start (points of profit)
input int    InpTrailDist        = 150;    // Trailing distance (points)
input int    InpTrailStep        = 20;     // Trailing step (points)
input double InpPartialPct       = 50.0;   // Partial close (% of volume)

input group "=== Notifications ==="
input bool   InpPopupAlerts      = true;   // Popup alert when a limit is hit
input bool   InpPushAlerts       = false;  // Push notification to mobile

input group "=== General ==="
input ulong  InpMagic            = 20260512; // Magic number
input int    InpSlippage         = 20;       // Max slippage (points)
input bool   InpManageAllMagic   = false;    // Manage trades of all magics on this symbol
input int    InpPanelX           = 15;       // Panel X
input int    InpPanelY           = 25;       // Panel Y

//--- constants
#define PFX "SMM_"
#define PW  330

//--- palette
#define C_BG        C'16,20,31'
#define C_HEADER    C'24,31,52'
#define C_CARD      C'25,31,48'
#define C_BORDER    C'44,54,84'
#define C_TEXT      C'226,232,245'
#define C_MUTED     C'128,140,170'
#define C_ACCENT    C'0,214,160'
#define C_BUY       C'0,172,112'
#define C_SELL      C'226,62,87'
#define C_WARN      C'255,170,50'
#define C_BTN       C'44,56,92'
#define C_BAR_BG    C'35,43,68'
#define C_BLIMIT    C'0,122,92'
#define C_SLIMIT    C'168,48,72'
#define C_BSTOP     C'0,140,170'
#define C_SSTOP     C'205,112,40'
#define C_ENTRY     C'90,170,255'

CTrade trade;

//--- runtime state
double gRisk, gRR, gLotFix;
int    gSL, gDist, gExpiry;
double gPeakEquity = 0;
string gStatus     = "Ready";
color  gStatusClr  = C_ACCENT;
bool   gLocked     = false;
string gLockReason = "";
string gWarn       = "";
string gLastReason = "";
int    gPanelH     = 0;
bool   gMin        = false;
int    gTab        = 0;      // active tab: 0 Account, 1 Setup, 2 Trade, 3 Manage
int    gCurTab     = -1;     // tab currently being built
int    gTabH[4];             // panel height per tab
string gObjs[];              // registered panel objects
int    gObjTab[];            // tab index of each registered object
int    gPrev       = 0;      // preview mode: 0 off, 1 BUY, 2 SELL, 3 BUY LIMIT, 4 SELL LIMIT, 5 BUY STOP, 6 SELL STOP

//--- daily statistics (cached)
double gRealized   = 0;
int    gTradesToday= 0;
int    gStreak     = 0;
uint   gStatsTick  = 0;

//--- news cache
bool   gNewsBlock  = false;
string gNewsInfo   = "";

//+------------------------------------------------------------------+
//| UI helpers                                                       |
//+------------------------------------------------------------------+
//--- object registry: tab of each panel object (-1 header, -2 tab bar, -3 status bar)
void Reg(string n)
  {
   if(gCurTab==-1) return;           // header objects are always visible
   int k=ArraySize(gObjs);
   ArrayResize(gObjs,k+1);
   ArrayResize(gObjTab,k+1);
   gObjs[k]=n;
   gObjTab[k]=gCurTab;
  }

void Rect(string name,int x,int y,int w,int h,color bg,color border)
  {
   string n=PFX+name;
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0); Reg(n); }
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,border);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
  }

void Lbl(string name,int x,int y,string txt,color clr,int size=9,string font="Segoe UI",
         ENUM_ANCHOR_POINT anchor=ANCHOR_LEFT_UPPER)
  {
   string n=PFX+name;
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_LABEL,0,0,0); Reg(n); }
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_FONT,font);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

void SetTxt(string name,string txt,color clr)
  {
   string n=PFX+name;
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
  }

void Btn(string name,int x,int y,int w,int h,string txt,color bg,color fg=C_TEXT,int size=10)
  {
   string n=PFX+name;
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_BUTTON,0,0,0); Reg(n); }
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_FONT,"Segoe UI Semibold");
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(0,n,OBJPROP_COLOR,fg);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

void Edt(string name,int x,int y,int w,int h,string txt)
  {
   string n=PFX+name;
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_EDIT,0,0,0); Reg(n); }
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_FONT,"Segoe UI Semibold");
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,n,OBJPROP_COLOR,C_ACCENT);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C_BAR_BG);
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,C_BORDER);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

//--- apply visibility + layout for the current tab (and minimize state)
void ApplyTab()
  {
   for(int i=0;i<ArraySize(gObjs);i++)
     {
      int tb=gObjTab[i];
      bool vis=(!gMin) && (tb<0 || tb==gTab);
      ObjectSetInteger(0,gObjs[i],OBJPROP_TIMEFRAMES,vis? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
     }

   // chart preview lines follow the minimize state
   int total=ObjectsTotal(0,0,-1);
   for(int i=0;i<total;i++)
     {
      string n=ObjectName(0,i,0,-1);
      if(StringFind(n,PFX+"pv_")!=0) continue;
      ObjectSetInteger(0,n,OBJPROP_TIMEFRAMES,gMin? OBJ_NO_PERIODS : OBJ_ALL_PERIODS);
     }

   // tab button colors
   for(int k=0;k<4;k++)
     {
      string n=PFX+"tab_"+IntegerToString(k);
      color bg=(k==gTab)? C_ACCENT : C_BTN;
      ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,bg);
      ObjectSetInteger(0,n,OBJPROP_COLOR,(k==gTab)? C_BG : C_TEXT);
     }

   // status bar sits right under the active tab's content
   int sy=InpPanelY+gTabH[gTab];
   ObjectSetInteger(0,PFX+"st_bg",OBJPROP_YDISTANCE,sy);
   ObjectSetInteger(0,PFX+"status",OBJPROP_YDISTANCE,sy+7);
   ObjectSetInteger(0,PFX+"bg",OBJPROP_YSIZE,gMin? 48 : gTabH[gTab]+28);
   ObjectSetString(0,PFX+"btn_min",OBJPROP_TEXT,gMin? "+" : "–");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Build the whole panel (tabbed)                                   |
//+------------------------------------------------------------------+
void BuildPanel()
  {
   int x=InpPanelX, y=InpPanelY;
   int pad=14, inner=PW-2*pad;
   int bw=(inner-8)/2;
   int cw=(inner-12)/3;
   int top=y+96;

   ArrayResize(gObjs,0);
   ArrayResize(gObjTab,0);

   // ---------------- header (always visible) ----------------
   gCurTab=-1;
   Rect("bg",x,y,PW,200,C_BG,C_BORDER);
   Rect("hdr",x,y,PW,46,C_HEADER,C_HEADER);
   Rect("hdr_line",x,y+46,PW,2,C_ACCENT,C_ACCENT);
   Lbl("title",x+pad,y+7,"SMART MONEY MANAGER",C_TEXT,11,"Segoe UI Semibold");
   Lbl("sub",x+pad,y+26,_Symbol+"  |  Risk Engine v2.2",C_MUTED,8);
   Btn("btn_min",x+PW-38,y+10,26,26,"–",C_BTN,C_TEXT,11);
   Lbl("dot",x+PW-48,y+13,"●",C_ACCENT,14,"Segoe UI",ANCHOR_RIGHT_UPPER);

   // ---------------- tab bar ----------------
   gCurTab=-2;
   int tw=(inner-9)/4;
   string tn[4]={"ACCOUNT","SETUP","TRADE","MANAGE"};
   for(int k=0;k<4;k++)
      Btn("tab_"+IntegerToString(k),x+pad+k*(tw+3),y+56,tw,26,tn[k],C_BTN,C_TEXT,8);

   // ---------------- status bar (moved by ApplyTab) ----------------
   gCurTab=-3;
   Rect("st_bg",x,y+300,PW,28,C_HEADER,C_HEADER);
   Lbl("status",x+pad,y+307,gStatus,gStatusClr,9);

   int cy;

   // ================= TAB 0 : ACCOUNT =================
   gCurTab=0;
   cy=top;
   Rect("c1",x+pad-4,cy-4,inner+8,118,C_CARD,C_BORDER);
   string rows[5]={"Balance","Equity","Floating P/L","Today P/L","Margin Level"};
   for(int i=0;i<5;i++)
     {
      Lbl("k"+IntegerToString(i),x+pad+4,cy+i*22+2,rows[i],C_MUTED,9);
      Lbl("v"+IntegerToString(i),x+PW-pad-4,cy+i*22+1,"-",C_TEXT,10,"Segoe UI Semibold",ANCHOR_RIGHT_UPPER);
     }
   cy+=128;

   Lbl("bar_t",x+pad,cy,"Daily loss limit",C_MUTED,8);
   Lbl("bar_v",x+PW-pad,cy,"0%",C_MUTED,8,"Segoe UI",ANCHOR_RIGHT_UPPER);
   Rect("bar_bg",x+pad,cy+18,inner,8,C_BAR_BG,C_BAR_BG);
   Rect("bar_fg",x+pad,cy+18,1,8,C_ACCENT,C_ACCENT);
   cy+=38;

   Lbl("dd_t",x+pad,cy,"Drawdown from peak",C_MUTED,8);
   Lbl("dd_v",x+PW-pad,cy,"0%",C_MUTED,8,"Segoe UI",ANCHOR_RIGHT_UPPER);
   Rect("dd_bg",x+pad,cy+18,inner,8,C_BAR_BG,C_BAR_BG);
   Rect("dd_fg",x+pad,cy+18,1,8,C_ACCENT,C_ACCENT);
   cy+=44;

   Rect("c3",x+pad-4,cy-4,inner+8,50,C_CARD,C_BORDER);
   Lbl("v_open",x+pad+4,cy+2,"-",C_MUTED,8);
   Lbl("v_chk",x+pad+4,cy+22,"-",C_MUTED,8);
   cy+=58;
   gTabH[0]=cy-y;

   // ================= TAB 1 : SETUP =================
   gCurTab=1;
   cy=top;
   Lbl("in_h",x+pad,cy,"TRADE SETUP",C_ACCENT,8,"Segoe UI Semibold");
   cy+=18;
   Lbl("l_risk",x+pad,cy,"Risk %",C_MUTED,8);
   Lbl("l_sl",x+pad+cw+6,cy,"SL (pts)",C_MUTED,8);
   Lbl("l_rr",x+pad+2*(cw+6),cy,"R : R",C_MUTED,8);
   cy+=15;
   Edt("e_risk",x+pad,cy,cw,26,DoubleToString(gRisk,2));
   Edt("e_sl",x+pad+cw+6,cy,cw,26,IntegerToString(gSL));
   Edt("e_rr",x+pad+2*(cw+6),cy,cw,26,DoubleToString(gRR,1));
   cy+=34;
   Lbl("l_dist",x+pad,cy,"Pending dist (pts)",C_MUTED,8);
   Lbl("l_exp",x+pad+cw+6,cy,"Expiry (min)",C_MUTED,8);
   Lbl("l_lot",x+pad+2*(cw+6),cy,"Lot (0=auto)",C_MUTED,8);
   cy+=15;
   Edt("e_dist",x+pad,cy,cw,26,IntegerToString(gDist));
   Edt("e_exp",x+pad+cw+6,cy,cw,26,IntegerToString(gExpiry));
   Edt("e_lot",x+pad+2*(cw+6),cy,cw,26,DoubleToString(gLotFix,2));
   cy+=40;

   Rect("c2",x+pad-4,cy-4,inner+8,56,C_CARD,C_BORDER);
   Lbl("k_lot",x+pad+4,cy+2,"Position size",C_MUTED,9);
   Lbl("v_lot",x+PW-pad-4,cy,"-",C_ACCENT,12,"Segoe UI Semibold",ANCHOR_RIGHT_UPPER);
   Lbl("k_rk",x+pad+4,cy+28,"Risk",C_MUTED,9);
   Lbl("v_rk",x+pad+50,cy+27,"-",C_SELL,9,"Segoe UI Semibold");
   Lbl("k_rw",x+PW/2+10,cy+28,"Reward",C_MUTED,9);
   Lbl("v_rw",x+PW-pad-4,cy+27,"-",C_BUY,9,"Segoe UI Semibold",ANCHOR_RIGHT_UPPER);
   cy+=68;

   Btn("btn_prev",x+pad,cy,inner,28,"Preview lines: OFF",C_BTN,C_MUTED,9);
   cy+=40;
   gTabH[1]=cy-y;

   // ================= TAB 2 : TRADE =================
   gCurTab=2;
   cy=top;
   Rect("c4",x+pad-4,cy-4,inner+8,32,C_CARD,C_BORDER);
   Lbl("v_lot2",x+pad+4,cy+3,"-",C_ACCENT,9,"Segoe UI Semibold");
   Lbl("v_rk2",x+PW/2,cy+3,"-",C_SELL,9,"Segoe UI Semibold",ANCHOR_UPPER);
   Lbl("v_rw2",x+PW-pad-4,cy+3,"-",C_BUY,9,"Segoe UI Semibold",ANCHOR_RIGHT_UPPER);
   cy+=44;

   Lbl("h_mkt",x+pad,cy,"MARKET",C_ACCENT,8,"Segoe UI Semibold");
   cy+=16;
   Btn("btn_buy",x+pad,cy,bw,40,"BUY",C_BUY,clrWhite,12);
   Btn("btn_sell",x+pad+bw+8,cy,bw,40,"SELL",C_SELL,clrWhite,12);
   cy+=52;

   Lbl("h_pend",x+pad,cy,"PENDING ORDERS",C_ACCENT,8,"Segoe UI Semibold");
   cy+=16;
   Btn("btn_bl",x+pad,cy,bw,32,"BUY LIMIT",C_BLIMIT,clrWhite,9);
   Btn("btn_sl",x+pad+bw+8,cy,bw,32,"SELL LIMIT",C_SLIMIT,clrWhite,9);
   cy+=38;
   Btn("btn_bs",x+pad,cy,bw,32,"BUY STOP",C_BSTOP,clrWhite,9);
   Btn("btn_ss",x+pad+bw+8,cy,bw,32,"SELL STOP",C_SSTOP,clrWhite,9);
   cy+=44;
   gTabH[2]=cy-y;

   // ================= TAB 3 : MANAGE =================
   gCurTab=3;
   cy=top;
   Lbl("h_mng",x+pad,cy,"ACTIONS",C_ACCENT,8,"Segoe UI Semibold");
   cy+=16;
   Btn("btn_be",x+pad,cy,bw,30,"Break-even",C_BTN,C_TEXT,9);
   Btn("btn_part",x+pad+bw+8,cy,bw,30,"Partial close",C_BTN,C_TEXT,9);
   cy+=36;
   Btn("btn_cw",x+pad,cy,bw,30,"Close winners",C_BTN,C_TEXT,9);
   Btn("btn_cl",x+pad+bw+8,cy,bw,30,"Close losers",C_BTN,C_TEXT,9);
   cy+=36;
   Btn("btn_close",x+pad,cy,bw,30,"Close all",C_BTN,C_TEXT,9);
   Btn("btn_delp",x+pad+bw+8,cy,bw,30,"Delete pendings",C_BTN,C_TEXT,9);
   cy+=44;

   Lbl("h_auto",x+pad,cy,"AUTOMATION",C_ACCENT,8,"Segoe UI Semibold");
   cy+=18;
   Rect("c5",x+pad-4,cy-4,inner+8,76,C_CARD,C_BORDER);
   string s1="Auto break-even:  "+(InpUseBE? "ON   (at +"+IntegerToString(InpBETrigger)+" pts)" : "OFF");
   string s2="Trailing stop:  "+(InpUseTrail? "ON   (start "+IntegerToString(InpTrailStart)+", dist "+IntegerToString(InpTrailDist)+")" : "OFF");
   string s3="Partial close:  "+DoubleToString(InpPartialPct,0)+"% of volume";
   Lbl("a1",x+pad+4,cy+2,s1,InpUseBE? C_ACCENT : C_MUTED,9);
   Lbl("a2",x+pad+4,cy+24,s2,InpUseTrail? C_ACCENT : C_MUTED,9);
   Lbl("a3",x+pad+4,cy+46,s3,C_TEXT,9);
   cy+=84;
   gTabH[3]=cy-y;

   // ---------------- finish ----------------
   gCurTab=-1;
   ObjectSetInteger(0,PFX+"bg",OBJPROP_ZORDER,0);
   ApplyTab();
  }

//+------------------------------------------------------------------+
//| Money management math                                            |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(st<=0) st=0.01;
   lot=MathFloor(lot/st+1e-9)*st;
   lot=MathMax(mn,MathMin(mx,lot));
   int digits=(int)MathMax(0,MathRound(-MathLog10(st)));
   return NormalizeDouble(lot,digits);
  }

double TickValueLoss()
  {
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv<=0) tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   return tv;
  }

double LossPerLot(int slPts)
  {
   double tv=TickValueLoss();
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) ts=_Point;
   return slPts*_Point/ts*tv;
  }

double RiskMoney()
  {
   return AccountInfoDouble(ACCOUNT_BALANCE)*gRisk/100.0;
  }

double CalcLot()
  {
   if(gLotFix>0) return NormalizeLot(gLotFix);
   double lpl=LossPerLot(gSL);
   if(lpl<=0) return 0;
   return NormalizeLot(RiskMoney()/lpl);
  }

//+------------------------------------------------------------------+
//| Account statistics                                               |
//+------------------------------------------------------------------+
bool MyPos(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) return false;
   if(!InpManageAllMagic && (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) return false;
   return true;
  }

bool MyOrder(ulong ticket)
  {
   if(!OrderSelect(ticket)) return false;
   if(OrderGetString(ORDER_SYMBOL)!=_Symbol) return false;
   if(!InpManageAllMagic && (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic) return false;
   return true;
  }

int CountPositions()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(MyPos(PositionGetTicket(i))) c++;
   return c;
  }

int CountPendings()
  {
   int c=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
      if(MyOrder(OrderGetTicket(i))) c++;
   return c;
  }

double FloatingPL()
  {
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t>0 && PositionSelectByTicket(t))
         p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return p;
  }

//--- realized P/L, trades opened and consecutive-loss streak for today (cached ~1s)
void UpdateStats(bool force=false)
  {
   uint now=GetTickCount();
   if(!force && now-gStatsTick<1000) return;
   gStatsTick=now;

   MqlDateTime d; TimeToStruct(TimeCurrent(),d);
   d.hour=0; d.min=0; d.sec=0;
   datetime from=StructToTime(d);

   gRealized=0; gTradesToday=0; gStreak=0;
   if(!HistorySelect(from,TimeCurrent()+60)) return;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong t=HistoryDealGetTicket(i);
      if(t==0) continue;
      long type=HistoryDealGetInteger(t,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      long entry=HistoryDealGetInteger(t,DEAL_ENTRY);

      if(entry==DEAL_ENTRY_IN)
        {
         gRealized+=HistoryDealGetDouble(t,DEAL_COMMISSION)+HistoryDealGetDouble(t,DEAL_FEE);
         if(InpManageAllMagic || (ulong)HistoryDealGetInteger(t,DEAL_MAGIC)==InpMagic) gTradesToday++;
         continue;
        }
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_INOUT && entry!=DEAL_ENTRY_OUT_BY) continue;

      double net=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)
                +HistoryDealGetDouble(t,DEAL_COMMISSION)+HistoryDealGetDouble(t,DEAL_FEE);
      gRealized+=net;
      if(net<0) gStreak++;
      else if(net>0) gStreak=0;
     }
  }

//--- money at risk (SL-implied) of one position/order
double RiskOf(double vol,double price,double sl,bool buy)
  {
   if(sl<=0) return 0;
   double dist=buy? price-sl : sl-price;
   if(dist<=0) return 0; // SL already beyond entry in profit
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) ts=_Point;
   return vol*dist/ts*TickValueLoss();
  }

double OpenRiskMoney()
  {
   double sum=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || !MyPos(t)) continue;
      bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      sum+=RiskOf(PositionGetDouble(POSITION_VOLUME),PositionGetDouble(POSITION_PRICE_OPEN),
                  PositionGetDouble(POSITION_SL),buy);
     }
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t=OrderGetTicket(i);
      if(t==0 || !MyOrder(t)) continue;
      long ot=OrderGetInteger(ORDER_TYPE);
      bool buy=(ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY_STOP);
      sum+=RiskOf(OrderGetDouble(ORDER_VOLUME_CURRENT),OrderGetDouble(ORDER_PRICE_OPEN),
                  OrderGetDouble(ORDER_SL),buy);
     }
   return sum;
  }

//+------------------------------------------------------------------+
//| Notifications                                                    |
//+------------------------------------------------------------------+
void Notify(string msg)
  {
   if(InpPopupAlerts) Alert(msg);
   if(InpPushAlerts) SendNotification(msg);
  }

void SetStatus(string s,color c)
  {
   gStatus=s; gStatusClr=c;
   SetTxt("status",s,c);
  }

//+------------------------------------------------------------------+
//| Filters: hours, spread, news, trades per day                     |
//+------------------------------------------------------------------+
bool InTradingHours()
  {
   if(!InpUseHours || InpStartHour==InpEndHour) return true;
   MqlDateTime d; TimeToStruct(TimeTradeServer(),d);
   int h=d.hour;
   if(InpStartHour<InpEndHour) return (h>=InpStartHour && h<InpEndHour);
   return (h>=InpStartHour || h<InpEndHour); // overnight window
  }

void RefreshNews()
  {
   gNewsBlock=false; gNewsInfo="";
   if(InpNewsLevel==NEWS_OFF) return;

   datetime now=TimeTradeServer();
   datetime from=now-InpNewsAfter*60;
   datetime to=now+InpNewsBefore*60;
   int minImp=(InpNewsLevel==NEWS_HIGH)? (int)CALENDAR_IMPORTANCE_HIGH : (int)CALENDAR_IMPORTANCE_MODERATE;

   string cur[2];
   cur[0]=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE);
   cur[1]=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT);

   for(int c=0;c<2;c++)
     {
      if(cur[c]=="" || (c==1 && cur[1]==cur[0])) continue;
      MqlCalendarValue vals[];
      if(!CalendarValueHistory(vals,from,to,NULL,cur[c])) continue;
      for(int i=0;i<ArraySize(vals);i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id,ev)) continue;
         if((int)ev.importance<minImp) continue;
         gNewsBlock=true;
         gNewsInfo=cur[c]+" "+ev.name;
         return;
        }
     }
  }

bool GateBlocked(string &why)
  {
   why="";
   if(!InTradingHours())
     { why="Outside trading hours"; return true; }
   if(InpMaxSpread>0 && SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)>InpMaxSpread)
     { why="Spread too high"; return true; }
   if(gNewsBlock)
     { why="News: "+gNewsInfo; return true; }
   if(InpMaxTradesPerDay>0 && gTradesToday>=InpMaxTradesPerDay)
     { why="Max trades per day reached"; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| Protection logic                                                 |
//+------------------------------------------------------------------+
void CheckLimits(double todayTotal,double dayStartBal,double ddPct)
  {
   double pct=(dayStartBal>0)? todayTotal/dayStartBal*100.0 : 0;
   string reason="";

   if(InpMaxDailyLossPct>0 && pct<=-InpMaxDailyLossPct)            reason="Daily loss limit reached";
   else if(InpMaxDrawdownPct>0 && ddPct>=InpMaxDrawdownPct)        reason="Max drawdown reached";
   else if(InpMaxDailyProfitPct>0 && pct>=InpMaxDailyProfitPct)    reason="Daily profit target reached";
   else if(InpMaxLossStreak>0 && gStreak>=InpMaxLossStreak)        reason="Loss streak limit reached";

   gLockReason=reason;
   gLocked=(reason!="" && InpLockAction!=LOCK_ALERT);
   gWarn=(reason!="" && InpLockAction==LOCK_ALERT)? reason : "";

   // act only once when a limit is first hit
   if(reason!="" && reason!=gLastReason)
     {
      Notify("Smart Money Manager: "+reason+(gLocked? " - trading locked." : " (alert only)."));
      if(InpLockAction==LOCK_HARD)
        {
         CloseAll();
         DeletePendings();
        }
     }
   gLastReason=reason;
  }

//+------------------------------------------------------------------+
//| Pre-trade checks shared by market and pending orders             |
//+------------------------------------------------------------------+
bool PreChecks(double &lot)
  {
   UpdateStats(true);

   if(gLocked)
     { SetStatus("Locked: "+gLockReason,C_SELL); return false; }

   string why;
   if(GateBlocked(why))
     { SetStatus(why,C_WARN); return false; }

   if(CountPositions()+CountPendings()>=InpMaxPositions)
     { SetStatus("Max trades reached ("+IntegerToString(InpMaxPositions)+")",C_WARN); return false; }

   long stopsLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long spread=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(gSL<=stopsLvl+spread)
     { SetStatus("SL too small for this symbol",C_WARN); return false; }

   lot=CalcLot();
   if(lot<=0)
     { SetStatus("Lot calculation failed",C_SELL); return false; }

   if(InpMaxOpenRiskPct>0)
     {
      double cap=AccountInfoDouble(ACCOUNT_BALANCE)*InpMaxOpenRiskPct/100.0;
      double after=OpenRiskMoney()+lot*LossPerLot(gSL);
      if(after>cap)
        { SetStatus("Open risk limit would be exceeded",C_WARN); return false; }
     }
   return true;
  }

bool MarginOK(ENUM_ORDER_TYPE type,double lot,double price)
  {
   ENUM_ORDER_TYPE mt=(type==ORDER_TYPE_BUY || type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP)?
                      ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin=0;
   if(OrderCalcMargin(mt,_Symbol,lot,price,margin))
      if(margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95)
        { SetStatus("Not enough free margin",C_SELL); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Order helpers                                                    |
//+------------------------------------------------------------------+
string OrderName(ENUM_ORDER_TYPE t)
  {
   switch(t)
     {
      case ORDER_TYPE_BUY:        return "BUY";
      case ORDER_TYPE_SELL:       return "SELL";
      case ORDER_TYPE_BUY_LIMIT:  return "BUY LIMIT";
      case ORDER_TYPE_SELL_LIMIT: return "SELL LIMIT";
      case ORDER_TYPE_BUY_STOP:   return "BUY STOP";
      case ORDER_TYPE_SELL_STOP:  return "SELL STOP";
     }
   return "ORDER";
  }

bool IsBuyType(ENUM_ORDER_TYPE t)
  {
   return (t==ORDER_TYPE_BUY || t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_BUY_STOP);
  }

double PendingPrice(ENUM_ORDER_TYPE type)
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double d=gDist*_Point;
   double p=0;
   switch(type)
     {
      case ORDER_TYPE_BUY_LIMIT:  p=ask-d; break;
      case ORDER_TYPE_BUY_STOP:   p=ask+d; break;
      case ORDER_TYPE_SELL_LIMIT: p=bid+d; break;
      case ORDER_TYPE_SELL_STOP:  p=bid-d; break;
      default: p=0;
     }
   return NormalizeDouble(p,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| Market orders                                                    |
//+------------------------------------------------------------------+
void OpenTrade(bool buy)
  {
   double lot=0;
   if(!PreChecks(lot)) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=buy? ask:bid;
   if(!MarginOK(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,lot,price)) return;

   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double sl=buy? price-gSL*_Point : price+gSL*_Point;
   double tp=0;
   if(gRR>0) tp=buy? price+gSL*gRR*_Point : price-gSL*gRR*_Point;
   sl=NormalizeDouble(sl,dg);
   if(tp>0) tp=NormalizeDouble(tp,dg);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok=buy? trade.Buy(lot,_Symbol,0,sl,tp,"SMM") : trade.Sell(lot,_Symbol,0,sl,tp,"SMM");

   if(ok && (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_PLACED))
     {
      SetStatus((buy?"BUY ":"SELL ")+DoubleToString(lot,2)+" lots opened",C_ACCENT);
      UpdateStats(true);
     }
   else
      SetStatus("Order failed: "+trade.ResultRetcodeDescription(),C_SELL);
  }

//+------------------------------------------------------------------+
//| Pending orders (Limit / Stop)                                    |
//+------------------------------------------------------------------+
void OpenPending(ENUM_ORDER_TYPE type)
  {
   double lot=0;
   if(!PreChecks(lot)) return;

   long stopsLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(gDist<=stopsLvl)
     { SetStatus("Distance must be > "+IntegerToString((int)stopsLvl)+" pts",C_WARN); return; }

   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   bool buy=IsBuyType(type);
   double price=PendingPrice(type);
   if(price<=0) { SetStatus("Invalid entry price",C_SELL); return; }
   if(!MarginOK(type,lot,price)) return;

   double sl=buy? price-gSL*_Point : price+gSL*_Point;
   double tp=0;
   if(gRR>0) tp=buy? price+gSL*gRR*_Point : price-gSL*gRR*_Point;
   sl=NormalizeDouble(sl,dg);
   if(tp>0) tp=NormalizeDouble(tp,dg);

   ENUM_ORDER_TYPE_TIME tt=(gExpiry>0)? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
   datetime exp=(gExpiry>0)? TimeCurrent()+gExpiry*60 : 0;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok=false;
   switch(type)
     {
      case ORDER_TYPE_BUY_LIMIT:  ok=trade.BuyLimit(lot,price,_Symbol,sl,tp,tt,exp,"SMM");  break;
      case ORDER_TYPE_BUY_STOP:   ok=trade.BuyStop(lot,price,_Symbol,sl,tp,tt,exp,"SMM");   break;
      case ORDER_TYPE_SELL_LIMIT: ok=trade.SellLimit(lot,price,_Symbol,sl,tp,tt,exp,"SMM"); break;
      case ORDER_TYPE_SELL_STOP:  ok=trade.SellStop(lot,price,_Symbol,sl,tp,tt,exp,"SMM");  break;
      default: break;
     }

   if(ok && (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_PLACED))
      SetStatus(OrderName(type)+" "+DoubleToString(lot,2)+" @ "+DoubleToString(price,dg),C_ACCENT);
   else
      SetStatus("Pending failed: "+trade.ResultRetcodeDescription(),C_SELL);
  }

void DeletePendings()
  {
   int n=0;
   trade.SetExpertMagicNumber(InpMagic);
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t=OrderGetTicket(i);
      if(t>0 && MyOrder(t))
         if(trade.OrderDelete(t)) n++;
     }
   SetStatus("Deleted "+IntegerToString(n)+" pending order(s)",C_ACCENT);
  }

//+------------------------------------------------------------------+
//| Position actions                                                 |
//+------------------------------------------------------------------+
void CloseAll()
  {
   int n=0;
   trade.SetExpertMagicNumber(InpMagic);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t>0 && MyPos(t))
         if(trade.PositionClose(t,InpSlippage)) n++;
     }
   SetStatus("Closed "+IntegerToString(n)+" position(s)",C_ACCENT);
  }

void CloseByProfit(bool winners)
  {
   int n=0;
   trade.SetExpertMagicNumber(InpMagic);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || !MyPos(t)) continue;
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if((winners && p>0) || (!winners && p<0))
         if(trade.PositionClose(t,InpSlippage)) n++;
     }
   SetStatus("Closed "+IntegerToString(n)+(winners? " winner(s)" : " loser(s)"),C_ACCENT);
  }

void PartialCloseAll()
  {
   int n=0;
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   trade.SetExpertMagicNumber(InpMagic);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || !MyPos(t)) continue;
      double vol=PositionGetDouble(POSITION_VOLUME);
      double part=NormalizeLot(vol*InpPartialPct/100.0);
      if(part>=vol || vol-part<mn) continue; // keep at least the minimum lot
      if(trade.PositionClosePartial(t,part,InpSlippage)) n++;
     }
   SetStatus("Partial close on "+IntegerToString(n)+" position(s)",n>0? C_ACCENT : C_WARN);
  }

void BreakEvenAll()
  {
   int n=0;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || !MyPos(t)) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(type==POSITION_TYPE_BUY)
        {
         double nsl=NormalizeDouble(op+InpBEOffset*_Point,dg);
         if(bid>nsl && (sl==0 || nsl>sl)) { if(trade.PositionModify(t,nsl,tp)) n++; }
        }
      else
        {
         double nsl=NormalizeDouble(op-InpBEOffset*_Point,dg);
         if(ask<nsl && (sl==0 || nsl<sl)) { if(trade.PositionModify(t,nsl,tp)) n++; }
        }
     }
   SetStatus("Break-even set on "+IntegerToString(n)+" position(s)",C_ACCENT);
  }

//+------------------------------------------------------------------+
//| Automatic BE + trailing                                          |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!InpUseBE && !InpUseTrail) return;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   long stopsLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || !MyPos(t)) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
        {
         double profitPts=(bid-op)/_Point;
         double target=sl;
         if(InpUseBE && profitPts>=InpBETrigger)
           {
            double be=op+InpBEOffset*_Point;
            if(sl==0 || be>target) target=be;
           }
         if(InpUseTrail && profitPts>=InpTrailStart)
           {
            double tr=bid-InpTrailDist*_Point;
            if(tr>target+InpTrailStep*_Point || (sl==0 && tr>0)) target=tr;
           }
         target=NormalizeDouble(target,dg);
         if(target>sl+_Point*0.5 && (bid-target)/_Point>stopsLvl)
            trade.PositionModify(t,target,tp);
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double profitPts=(op-ask)/_Point;
         double target=sl;
         if(InpUseBE && profitPts>=InpBETrigger)
           {
            double be=op-InpBEOffset*_Point;
            if(sl==0 || be<target) target=be;
           }
         if(InpUseTrail && profitPts>=InpTrailStart)
           {
            double tr=ask+InpTrailDist*_Point;
            if(sl==0 || tr<target-InpTrailStep*_Point) target=tr;
           }
         target=NormalizeDouble(target,dg);
         if(sl==0 || target<sl-_Point*0.5)
            if((target-ask)/_Point>stopsLvl && target>0)
               trade.PositionModify(t,target,tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Chart preview lines (entry / SL / TP before clicking)            |
//+------------------------------------------------------------------+
string PrevLabel()
  {
   switch(gPrev)
     {
      case 1: return "BUY";
      case 2: return "SELL";
      case 3: return "BUY LIMIT";
      case 4: return "SELL LIMIT";
      case 5: return "BUY STOP";
      case 6: return "SELL STOP";
     }
   return "OFF";
  }

ENUM_ORDER_TYPE PrevType()
  {
   switch(gPrev)
     {
      case 1: return ORDER_TYPE_BUY;
      case 2: return ORDER_TYPE_SELL;
      case 3: return ORDER_TYPE_BUY_LIMIT;
      case 4: return ORDER_TYPE_SELL_LIMIT;
      case 5: return ORDER_TYPE_BUY_STOP;
      case 6: return ORDER_TYPE_SELL_STOP;
     }
   return ORDER_TYPE_BUY;
  }

void PHLine(string name,double price,color clr,ENUM_LINE_STYLE style)
  {
   string n=PFX+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,n,OBJPROP_PRICE,price);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,n,OBJPROP_STYLE,style);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_BACK,true);
  }

void PText(string name,datetime t,double price,string txt,color clr)
  {
   string n=PFX+name;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_TEXT,0,t,price);
   ObjectSetInteger(0,n,OBJPROP_TIME,t);
   ObjectSetDouble(0,n,OBJPROP_PRICE,price);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetString(0,n,OBJPROP_FONT,"Segoe UI Semibold");
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_RIGHT_LOWER);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

string Money(double v)
  {
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   return (v<0?"-":"")+DoubleToString(MathAbs(v),2)+" "+cur;
  }

void UpdatePreview()
  {
   if(gPrev==0)
     {
      ObjectsDeleteAll(0,PFX+"pv_");
      return;
     }

   ENUM_ORDER_TYPE ty=PrevType();
   bool buy=IsBuyType(ty);
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   double entry;
   if(ty==ORDER_TYPE_BUY)       entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   else if(ty==ORDER_TYPE_SELL) entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   else                         entry=PendingPrice(ty);
   if(entry<=0) return;

   double sl=NormalizeDouble(buy? entry-gSL*_Point : entry+gSL*_Point,dg);
   double tp=(gRR>0)? NormalizeDouble(buy? entry+gSL*gRR*_Point : entry-gSL*gRR*_Point,dg) : 0;
   double lot=CalcLot();
   double risk=lot*LossPerLot(gSL);

   // labels sit at the right edge of the visible chart
   int first=(int)ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR);
   int vis=(int)ChartGetInteger(0,CHART_VISIBLE_BARS);
   int idx=MathMax(0,first-vis+1);
   datetime t=iTime(_Symbol,_Period,idx);

   PHLine("pv_e",entry,C_ENTRY,STYLE_DASH);
   PText("pv_et",t,entry,OrderName(ty)+"  "+DoubleToString(lot,2)+" lot @ "+DoubleToString(entry,dg),C_ENTRY);

   PHLine("pv_sl",sl,C_SELL,STYLE_DOT);
   PText("pv_slt",t,sl,"SL "+DoubleToString(sl,dg)+"   "+Money(-risk),C_SELL);

   if(tp>0)
     {
      PHLine("pv_tp",tp,C_BUY,STYLE_DOT);
      PText("pv_tpt",t,tp,"TP "+DoubleToString(tp,dg)+"   +"+Money(risk*gRR),C_BUY);
     }
   else
     {
      ObjectDelete(0,PFX+"pv_tp");
      ObjectDelete(0,PFX+"pv_tpt");
     }
  }

//+------------------------------------------------------------------+
//| Panel refresh                                                    |
//+------------------------------------------------------------------+
color PLColor(double v) { return v>0? C_ACCENT : (v<0? C_SELL : C_TEXT); }

void UpdatePanel()
  {
   UpdateStats();

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double fl=FloatingPL();
   double today=gRealized+fl;
   double dayStart=bal-gRealized;
   if(dayStart<=0) dayStart=bal;

   if(eq>gPeakEquity) gPeakEquity=eq;
   double ddPct=(gPeakEquity>0)? (gPeakEquity-eq)/gPeakEquity*100.0 : 0;
   if(ddPct<0) ddPct=0;

   // limits are evaluated even while the panel is minimized
   CheckLimits(today,dayStart,ddPct);
   SetTxt("dot","●",gLocked? C_SELL : (gWarn!=""? C_WARN : C_ACCENT));
   if(gMin) { ChartRedraw(); return; }

   double ml=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double used=AccountInfoDouble(ACCOUNT_MARGIN);

   SetTxt("v0",Money(bal),C_TEXT);
   SetTxt("v1",Money(eq),C_TEXT);
   SetTxt("v2",Money(fl),PLColor(fl));
   SetTxt("v3",Money(today),PLColor(today));
   SetTxt("v4",used>0? DoubleToString(ml,0)+" %" : "-",(ml>0 && ml<150)? C_SELL : C_TEXT);

   // daily loss bar
   int inner=PW-28;
   double lossPct=(today<0)? -today/dayStart*100.0 : 0;
   double use=(InpMaxDailyLossPct>0)? MathMin(1.0,lossPct/InpMaxDailyLossPct) : 0;
   color bc=use<0.5? C_ACCENT : (use<0.8? C_WARN : C_SELL);
   ObjectSetInteger(0,PFX+"bar_fg",OBJPROP_XSIZE,MathMax(1,(int)(inner*use)));
   ObjectSetInteger(0,PFX+"bar_fg",OBJPROP_BGCOLOR,bc);
   ObjectSetInteger(0,PFX+"bar_fg",OBJPROP_COLOR,bc);
   SetTxt("bar_v",DoubleToString(lossPct,2)+"% / "+DoubleToString(InpMaxDailyLossPct,1)+"%",bc);

   double duse=(InpMaxDrawdownPct>0)? MathMin(1.0,ddPct/InpMaxDrawdownPct) : 0;
   color dc=duse<0.5? C_ACCENT : (duse<0.8? C_WARN : C_SELL);
   ObjectSetInteger(0,PFX+"dd_fg",OBJPROP_XSIZE,MathMax(1,(int)(inner*duse)));
   ObjectSetInteger(0,PFX+"dd_fg",OBJPROP_BGCOLOR,dc);
   ObjectSetInteger(0,PFX+"dd_fg",OBJPROP_COLOR,dc);
   SetTxt("dd_v",DoubleToString(ddPct,2)+"% / "+DoubleToString(InpMaxDrawdownPct,1)+"%",dc);

   // computed values
   double lot=CalcLot();
   double riskMoney=lot*LossPerLot(gSL);
   SetTxt("v_lot",DoubleToString(lot,2)+" lot",C_ACCENT);
   SetTxt("v_rk",Money(riskMoney),C_SELL);
   SetTxt("v_rw",gRR>0? Money(riskMoney*gRR) : "-",C_BUY);
   SetTxt("v_lot2","Lot "+DoubleToString(lot,2),C_ACCENT);
   SetTxt("v_rk2","Risk "+Money(riskMoney),C_SELL);
   SetTxt("v_rw2",gRR>0? "Reward "+Money(riskMoney*gRR) : "No TP",C_BUY);
   SetTxt("v_open",
          "Open "+IntegerToString(CountPositions())+"   Pending "+IntegerToString(CountPendings())+
          "   Max "+IntegerToString(InpMaxPositions)+
          "   Spread "+IntegerToString((int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)),C_MUTED);

   // filter / limit summary line
   string why="";
   bool gate=GateBlocked(why);
   string chk="Today "+IntegerToString(gTradesToday)+
              (InpMaxTradesPerDay>0? "/"+IntegerToString(InpMaxTradesPerDay) : "")+" trades";
   chk+="  |  L-streak "+IntegerToString(gStreak)+
        (InpMaxLossStreak>0? "/"+IntegerToString(InpMaxLossStreak) : "");
   if(InpMaxOpenRiskPct>0)
      chk+="  |  Risk "+DoubleToString(OpenRiskMoney()/MathMax(1.0,bal)*100.0,1)+"%/"+
           DoubleToString(InpMaxOpenRiskPct,1)+"%";
   if(gate) chk=why;
   SetTxt("v_chk",chk,gate? C_WARN : C_MUTED);

   // status line
   if(gLocked) SetStatus("LOCKED: "+gLockReason,C_SELL);
   else if(gWarn!="") SetStatus("ALERT: "+gWarn,C_WARN);
   else if(StringFind(gStatus,"LOCKED")==0 || StringFind(gStatus,"ALERT:")==0) SetStatus("Ready",C_ACCENT);

   // order buttons look disabled while locked / gated
   bool off=(gLocked || gate);
   color dis=C_BAR_BG;
   ObjectSetInteger(0,PFX+"btn_buy",OBJPROP_BGCOLOR,off? dis : C_BUY);
   ObjectSetInteger(0,PFX+"btn_sell",OBJPROP_BGCOLOR,off? dis : C_SELL);
   ObjectSetInteger(0,PFX+"btn_bl",OBJPROP_BGCOLOR,off? dis : C_BLIMIT);
   ObjectSetInteger(0,PFX+"btn_sl",OBJPROP_BGCOLOR,off? dis : C_SLIMIT);
   ObjectSetInteger(0,PFX+"btn_bs",OBJPROP_BGCOLOR,off? dis : C_BSTOP);
   ObjectSetInteger(0,PFX+"btn_ss",OBJPROP_BGCOLOR,off? dis : C_SSTOP);

   UpdatePreview();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   gRisk=InpRiskPercent;
   gSL=InpSLPoints;
   gRR=InpRR;
   gLotFix=InpFixedLot;
   gDist=InpEntryDistance;
   gExpiry=InpExpiryMinutes;
   gPeakEquity=MathMax(AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY));

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   UpdateStats(true);
   RefreshNews();
   BuildPanel();
   EventSetTimer(1);
   UpdatePanel();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0,PFX);
   ChartRedraw();
  }

void OnTick()
  {
   ManagePositions();
   UpdatePanel();
  }

void OnTimer()
  {
   static int cnt=0;
   cnt++;
   if(cnt>=30) { cnt=0; RefreshNews(); }
   UpdatePanel();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
     {
      UpdateStats(true);
      UpdatePanel();
     }
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_CHART_CHANGE)
     {
      if(!gMin && gPrev>0) UpdatePreview();
      return;
     }

   if(id==CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam==PFX+"btn_min")        { gMin=!gMin; ApplyTab(); }
      else if(StringFind(sparam,PFX+"tab_")==0)
        {
         gTab=(int)StringToInteger(StringSubstr(sparam,StringLen(PFX)+4,1));
         ApplyTab();
        }
      else if(sparam==PFX+"btn_prev")
        {
         gPrev=(gPrev+1)%7;
         ObjectSetString(0,PFX+"btn_prev",OBJPROP_TEXT,"Preview lines: "+PrevLabel());
         ObjectSetInteger(0,PFX+"btn_prev",OBJPROP_COLOR,gPrev==0? C_MUTED : C_ENTRY);
         UpdatePreview();
        }
      else if(sparam==PFX+"btn_buy")   OpenTrade(true);
      else if(sparam==PFX+"btn_sell")  OpenTrade(false);
      else if(sparam==PFX+"btn_bl")    OpenPending(ORDER_TYPE_BUY_LIMIT);
      else if(sparam==PFX+"btn_sl")    OpenPending(ORDER_TYPE_SELL_LIMIT);
      else if(sparam==PFX+"btn_bs")    OpenPending(ORDER_TYPE_BUY_STOP);
      else if(sparam==PFX+"btn_ss")    OpenPending(ORDER_TYPE_SELL_STOP);
      else if(sparam==PFX+"btn_close") CloseAll();
      else if(sparam==PFX+"btn_cw")    CloseByProfit(true);
      else if(sparam==PFX+"btn_cl")    CloseByProfit(false);
      else if(sparam==PFX+"btn_delp")  DeletePendings();
      else if(sparam==PFX+"btn_be")    BreakEvenAll();
      else if(sparam==PFX+"btn_part")  PartialCloseAll();
      else return;
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      UpdatePanel();
     }
   else if(id==CHARTEVENT_OBJECT_ENDEDIT)
     {
      string txt=ObjectGetString(0,sparam,OBJPROP_TEXT);
      if(sparam==PFX+"e_risk")
        {
         gRisk=MathMax(0.01,MathMin(10.0,StringToDouble(txt)));
         ObjectSetString(0,sparam,OBJPROP_TEXT,DoubleToString(gRisk,2));
        }
      else if(sparam==PFX+"e_sl")
        {
         gSL=MathMax(10,(int)StringToInteger(txt));
         ObjectSetString(0,sparam,OBJPROP_TEXT,IntegerToString(gSL));
        }
      else if(sparam==PFX+"e_rr")
        {
         gRR=MathMax(0.0,MathMin(20.0,StringToDouble(txt)));
         ObjectSetString(0,sparam,OBJPROP_TEXT,DoubleToString(gRR,1));
        }
      else if(sparam==PFX+"e_dist")
        {
         gDist=MathMax(1,(int)StringToInteger(txt));
         ObjectSetString(0,sparam,OBJPROP_TEXT,IntegerToString(gDist));
        }
      else if(sparam==PFX+"e_exp")
        {
         gExpiry=MathMax(0,(int)StringToInteger(txt));
         ObjectSetString(0,sparam,OBJPROP_TEXT,IntegerToString(gExpiry));
        }
      else if(sparam==PFX+"e_lot")
        {
         gLotFix=MathMax(0.0,StringToDouble(txt));
         ObjectSetString(0,sparam,OBJPROP_TEXT,DoubleToString(gLotFix,2));
        }
      else return;
      UpdatePanel();
     }
  }
//+------------------------------------------------------------------+
