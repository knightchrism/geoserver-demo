<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
  xmlns="http://www.opengis.net/sld"
  xmlns:ogc="http://www.opengis.net/ogc"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.opengis.net/sld http://schemas.opengis.net/sld/1.0.0/StyledLayerDescriptor.xsd">
  <NamedLayer>
    <Name>hillshade</Name>
    <UserStyle>
      <Title>Hillshade</Title>
      <Abstract>8-bit hillshade. 0 is left dark, 255 is light. This is illumination, not elevation, so it does not use the -3 m to 19 m ramp.</Abstract>
      <FeatureTypeStyle>
        <Rule>
          <RasterSymbolizer>
            <Opacity>1.0</Opacity>
            <ColorMap type="ramp">
              <ColorMapEntry color="#2a2a2a" quantity="0" label="shadow"/>
              <ColorMapEntry color="#8d8d8d" quantity="128" label=""/>
              <ColorMapEntry color="#f7f7f7" quantity="255" label="light"/>
            </ColorMap>
          </RasterSymbolizer>
        </Rule>
      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>
